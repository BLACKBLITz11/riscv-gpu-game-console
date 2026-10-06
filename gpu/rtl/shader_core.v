module shader_core #(
    parameter CORE_ID = 0,
    parameter START_HALTED = 0   // 1 = come out of reset halted; wait for a start pulse
) (
    input         clk,
    input         rst,
    input         start,        // 1-cycle pulse: restart from HALTED; keeps local_mem
    input  [31:0] instruction,  // current 32-bit instruction
    output reg    done,         // pulses high when an instruction finishes
    output reg    halted,       // goes high (and stays high) after HALT
    output [7:0]  pc,           // this thread's own fetch address

    // memory interface
    output reg        mem_req,
    output reg        mem_we,
    output reg [9:0]  mem_addr,
    output reg [31:0] mem_wdata,
    input      [31:0] mem_rdata,
    input              mem_grant,  // not yet used -- see Day 5 note

    // host write port into this core's private local_mem (entity spawn /
    // respawn). gpu_top asserts host_lm_we only while ALL cores are halted.
    input              host_lm_we,
    input      [5:0]   host_lm_addr,
    input      [31:0]  host_lm_wdata,

    // read port into local_mem (asynchronous) -- used by the framebuffer
    input      [5:0]   host_lm_raddr,
    output     [31:0]  host_lm_rdata
);

    // ---- FSM states ----
    localparam FETCH     = 3'b000;
    localparam DECODE    = 3'b001;
    localparam EXECUTE   = 3'b010;
    localparam MEMORY    = 3'b011;
    localparam WRITEBACK = 3'b100;
    localparam HALTED    = 3'b101;

    reg [2:0] state;

    // Soft restart: only honored while HALTED. Resets PC + register file
    // (fresh R0.., R15=CORE_ID) but NOT local_mem or the shared memory.
    wire start_go = start && (state == HALTED);

    // ---- opcodes (must match the locked ISA table) ----
    localparam OP_ADD  = 6'b000000;
    localparam OP_SHR  = 6'b001101;  // last plain R-type ALU op
    localparam OP_CMP  = 6'b001110;
    localparam OP_BEQ  = 6'b001111;
    localparam OP_BNE  = 6'b010000;
    localparam OP_BGT  = 6'b010001;
    localparam OP_BLT  = 6'b010010;
    localparam OP_LDR  = 6'b010011;
    localparam OP_STR  = 6'b010100;
    localparam OP_MOVI = 6'b010101;
    localparam OP_HALT = 6'b010110;

    // ---- decoded/latched instruction fields ----
    reg [5:0]  opcode;
    reg [3:0]  rd, rs1, rs2;
    reg [31:0] imm;

    // ---- instruction-category latches (set in DECODE, held through WRITEBACK) ----
    reg is_r_alu, is_cmp, is_branch, is_ldr, is_str, is_movi, is_halt;

    // ---- ALU ----
    reg  [5:0]  alu_op;
    reg  [31:0] alu_a, alu_b;
    wire [31:0] alu_result;
    wire zero_flag, greater_flag, less_flag;

    alu alu_inst (
        .op(alu_op), .a(alu_a), .b(alu_b), .result(alu_result),
        .zero_flag(zero_flag), .greater_flag(greater_flag), .less_flag(less_flag)
    );

    // latched comparison flags -- persist from CMP until a later branch reads them
    reg flag_zero, flag_greater, flag_less;

    // ---- register file ----
    reg         we;
    wire [31:0] r_data1, r_data2;
    // captured memory-read value, for LDR
    reg [31:0] mem_data_reg;
    // combinational mux: what actually gets written to rd
    reg [31:0] rf_w_data;
    always @(*) begin
        if (is_ldr)       rf_w_data = mem_data_reg;
        else if (is_movi) rf_w_data = imm;
        else               rf_w_data = alu_result;
    end

    reg_file #(.CORE_ID(CORE_ID)) rf_inst (
        .clk(clk), .rst(rst | start_go), .we(we),
        .r_addr1(rs1), .r_addr2(rs2),
        .w_addr(rd), .w_data(rf_w_data),
        .r_data1(r_data1), .r_data2(r_data2)
    );

    // ---- program counter ----
    reg        jump;
    reg [7:0]  jump_addr;
    wire       stall;

    // PC advances only in WRITEBACK (once, when the instruction retires);
    // every other state holds it still, so FETCH/DECODE always see the
    // address of the instruction being executed.
    assign stall = (state != WRITEBACK);

    prog_counter pc_inst (
        .clk(clk), .rst(rst | start_go),
        .jump(jump), .jump_addr(jump_addr),
        .stall(stall),
        .pc(pc)
    );

    // ---- per-core private local memory ----
    // addresses 0-63 (LOCAL_SIZE) live here, accessed in a single cycle,
    // no arbitration -- addresses 64+ go to the shared mem_ctrl instead
    localparam LOCAL_SIZE = 64;
    reg [31:0] local_mem [0:LOCAL_SIZE-1];
`ifndef SYNTHESIS
    integer li;   // simulation only: clear on reset (on the FPGA it powers up as zeros)
`endif

    assign host_lm_rdata = local_mem[host_lm_raddr];

    // ONE write port, so the tools can build local_mem as a RAM. The host's
    // spawn write wins over a core store in the same cycle, as before.
    wire        lm_host_we = !rst && host_lm_we;
    wire        lm_core_we = !rst && (state == MEMORY) && is_str && (alu_result[9:0] < LOCAL_SIZE);
    wire        lm_we      = lm_host_we | lm_core_we;
    wire [5:0]  lm_waddr   = lm_host_we ? host_lm_addr  : alu_result[5:0];
    wire [31:0] lm_wdata   = lm_host_we ? host_lm_wdata : r_data2;

    always @(posedge clk) begin
        if (rst) begin
            state        <= START_HALTED ? HALTED : FETCH;
            done         <= 0;
            halted       <= START_HALTED ? 1'b1 : 1'b0;
            we           <= 0;
            jump         <= 0;
            mem_req      <= 0;
            mem_we       <= 0;
            mem_addr     <= 10'h0;
            mem_wdata    <= 32'h0;
            flag_zero    <= 0;
            flag_greater <= 0;
            flag_less    <= 0;
`ifndef SYNTHESIS
            for (li = 0; li < LOCAL_SIZE; li = li + 1)
                local_mem[li] <= 32'h0;
`endif
        end
        else if (start_go) begin
            // new tick: restart the FSM, keep local_mem
            state        <= FETCH;
            done         <= 0;
            halted       <= 0;
            we           <= 0;
            jump         <= 0;
            mem_req      <= 0;
            mem_we       <= 0;
            flag_zero    <= 0;
            flag_greater <= 0;
            flag_less    <= 0;
        end
        else begin
            case (state)

                FETCH: begin
                    we      <= 0;
                    jump    <= 0;
                    done    <= 0;
                    mem_req <= 0;
                    state   <= DECODE;
                end

                DECODE: begin
                    opcode <= instruction[31:26];
                    rd     <= instruction[25:22];
                    rs1    <= instruction[21:18];
                    // STR reuses the rs2 read port to fetch its "source" value
                    // (the field named rd holds that source register for STR)
                    rs2    <= (instruction[31:26] == OP_STR) ? instruction[25:22]
                                                              : instruction[17:14];
                    imm    <= {{14{instruction[17]}}, instruction[17:0]}; // sign-extend 18->32

                    is_r_alu  <= (instruction[31:26] <= OP_SHR);
                    is_cmp    <= (instruction[31:26] == OP_CMP);
                    is_branch <= (instruction[31:26] >= OP_BEQ) && (instruction[31:26] <= OP_BLT);
                    is_ldr    <= (instruction[31:26] == OP_LDR);
                    is_str    <= (instruction[31:26] == OP_STR);
                    is_movi   <= (instruction[31:26] == OP_MOVI);
                    is_halt   <= (instruction[31:26] == OP_HALT);

                    state <= EXECUTE;
                end

                EXECUTE: begin
                    if (is_r_alu || is_cmp) begin
                        alu_op <= opcode;
                        alu_a  <= r_data1;
                        alu_b  <= r_data2;
                    end
                    else if (is_ldr || is_str) begin
                        alu_op <= OP_ADD;      // address = rs1 + imm
                        alu_a  <= r_data1;
                        alu_b  <= imm;
                    end
                    else if (is_branch) begin
                        alu_op <= OP_ADD;      // target = pc + imm
                        alu_a  <= {24'h0, pc};
                        alu_b  <= imm;
                    end
                    // MOVI needs no ALU -- imm goes straight to rf_w_data

                    state <= MEMORY;
                end

                MEMORY: begin
                    // CMP's flags are latched HERE, not in EXECUTE -- alu_a/alu_b
                    // were only just set (via NBA) during the EXECUTE edge, so the
                    // ALU's combinational outputs only reflect them starting now.
                    if (is_cmp) begin
                        flag_zero    <= zero_flag;
                        flag_greater <= greater_flag;
                        flag_less    <= less_flag;
                    end

                    if ((is_ldr || is_str) && alu_result[9:0] < LOCAL_SIZE) begin
                        // LOCAL memory -- private to this core, no arbitration
                        // needed at all, completes in this single cycle
                        mem_req <= 0;
                        mem_we  <= 0;
                        if (is_ldr) begin
                            mem_data_reg <= local_mem[alu_result[5:0]];
                        end
                        // (a local STR is written by the single write port above)
                        state <= WRITEBACK;
                    end
                    else if (is_ldr || is_str) begin
                        // GLOBAL memory -- goes through the shared, arbitrated
                        // mem_ctrl, same as before. Address is rebased by
                        // LOCAL_SIZE so mem_ctrl's own space still starts at 0.
                        mem_req   <= 1;
                        mem_we    <= is_str;
                        mem_addr  <= alu_result[9:0] - LOCAL_SIZE;
                        if (is_str) mem_wdata <= r_data2;

                        if (mem_grant) begin
                            if (is_ldr) mem_data_reg <= mem_rdata;
                            mem_req <= 0;
                            state   <= WRITEBACK;
                        end
                        // else: not granted yet -- stay in MEMORY, try again next cycle
                    end
                    else begin
                        mem_req <= 0;
                        mem_we  <= 0;
                        state   <= WRITEBACK;
                    end
                end

                WRITEBACK: begin
                    we <= (is_r_alu || is_ldr || is_movi);  // CMP/branch/STR/HALT write nothing

                    if (is_branch) begin
                        case (opcode)
                            OP_BEQ:  jump <= flag_zero;
                            OP_BNE:  jump <= ~flag_zero;
                            OP_BGT:  jump <= flag_greater;
                            OP_BLT:  jump <= flag_less;
                            default: jump <= 0;
                        endcase
                        jump_addr <= alu_result[7:0];  // pc+imm, computed in EXECUTE
                    end
                    else begin
                        jump <= 0;
                    end

                    mem_req <= 0;
                    done    <= 1;

                    if (is_halt) begin
                        halted <= 1;
                        state  <= HALTED;
                    end
                    else begin
                        state <= FETCH;
                    end
                end

                HALTED: begin
                    // PC is frozen by stall (state != WRITEBACK) now, so no
                    // need to fake a freeze with a self-jump anymore.
                    jump    <= 0;
                    we      <= 0;
                    mem_req <= 0;
                    done    <= 1;
                    halted  <= 1;
                    state   <= HALTED;
                end

            endcase
        end

        // the single local_mem write port (host spawn write or core STR)
        if (lm_we)
            local_mem[lm_waddr] <= lm_wdata;
    end

endmodule