// control_unit.v
module control_unit (
    input        clk,
    input        rst,
    // from decoder
    input        is_lui,
    input        is_auipc,
    input        is_jal,
    input        is_jalr,
    input        is_branch,
    input        is_load,
    input        is_store,
    input        is_op_imm,
    input        is_op,
    input        illegal,
    input  [2:0] funct3,
    input        funct7_5,
    // from ALU
    input        eq,
    input        lt,
    input        ltu,
    // to datapath
    output       stall,
    output       pc_load,
    output       target_sel_alu,
    output       alu_a_sel_pc,
    output       alu_b_sel_imm,
    output [3:0] alu_op,
    output       rf_we,
    output [1:0] wb_sel,
    output       mem_we,
    output       mem_re,
    output       halted
);
    localparam S_FETCH  = 3'd0;
    localparam S_DECODE = 3'd1;
    localparam S_EXEC   = 3'd2;
    localparam S_MEM    = 3'd3;
    localparam S_WB     = 3'd4;
    localparam S_HALT   = 3'd5;

    reg [2:0] state;

    always @(posedge clk) begin
        if (rst)
            state <= S_FETCH;
        else begin
            case (state)
                S_FETCH:  state <= S_DECODE;
                S_DECODE: state <= illegal ? S_HALT : S_EXEC;
                S_EXEC:   if (is_branch)                state <= S_FETCH;
                          else if (is_load | is_store)  state <= S_MEM;
                          else                          state <= S_WB;
                S_MEM:    state <= is_load ? S_WB : S_FETCH;
                S_WB:     state <= S_FETCH;
                S_HALT:   state <= S_HALT;
                default:  state <= S_FETCH;
            endcase
        end
    end

    // branch decision from funct3
    reg branch_taken;
    always @* begin
        case (funct3)
            3'b000:  branch_taken = eq;     // beq
            3'b001:  branch_taken = ~eq;    // bne
            3'b100:  branch_taken = lt;     // blt
            3'b101:  branch_taken = ~lt;    // bge
            3'b110:  branch_taken = ltu;    // bltu
            3'b111:  branch_taken = ~ltu;   // bgeu
            default: branch_taken = 1'b0;
        endcase
    end

    wire in_exec = (state == S_EXEC);
    wire in_mem  = (state == S_MEM);
    wire in_wb   = (state == S_WB);

    // PC holds except in the last state of each instruction
    assign stall = in_exec ? ~is_branch :
                   in_mem  ? ~is_store  :
                   in_wb   ? 1'b0       : 1'b1;

    assign pc_load = (in_exec & is_branch & branch_taken) |
                     (in_wb   & (is_jal | is_jalr));
    assign target_sel_alu = is_jalr;

    assign alu_a_sel_pc  = is_auipc;
    assign alu_b_sel_imm = ~(is_op | is_branch);

    assign alu_op = is_op     ? {funct7_5, funct3} :
                    is_op_imm ? {(funct3 == 3'b101) & funct7_5, funct3} :
                                4'b0000;

    assign rf_we = in_wb & (is_op | is_op_imm | is_load | is_lui |
                            is_auipc | is_jal | is_jalr);

    // 00 = ALU result, 01 = memory/bus read, 10 = immediate, 11 = PC+4
    assign wb_sel = is_load            ? 2'b01 :
                    is_lui             ? 2'b10 :
                    (is_jal | is_jalr) ? 2'b11 : 2'b00;

    assign mem_we = in_mem & is_store;
    assign mem_re = in_mem & is_load;

    assign halted = (state == S_HALT);
endmodule