// cpu_core.v
module cpu_core (
    input         clk,
    input         rst,
    // instruction memory (synchronous read)
    output [31:0] imem_addr,
    input  [31:0] imem_data,
    // data bus
    output [31:0] bus_addr,
    output [31:0] bus_wdata,
    output        bus_we,
    output        bus_re,
    input  [31:0] bus_rdata,
    output        halted
);
    wire [31:0] instr = imem_data;

    wire [6:0]  opcode, funct7;
    wire [4:0]  rd, rs1, rs2;
    wire [2:0]  funct3;
    wire [31:0] imm;
    wire is_lui, is_auipc, is_jal, is_jalr, is_branch, is_load, is_store,
         is_op_imm, is_op, illegal;

    decoder u_dec (
        .instr(instr), .opcode(opcode), .rd(rd), .rs1(rs1), .rs2(rs2),
        .funct3(funct3), .funct7(funct7), .imm(imm),
        .is_lui(is_lui), .is_auipc(is_auipc), .is_jal(is_jal), .is_jalr(is_jalr),
        .is_branch(is_branch), .is_load(is_load), .is_store(is_store),
        .is_op_imm(is_op_imm), .is_op(is_op), .illegal(illegal)
    );

    wire        stall, pc_load, target_sel_alu, alu_a_sel_pc, alu_b_sel_imm;
    wire [3:0]  alu_op;
    wire        rf_we, mem_we, mem_re;
    wire [1:0]  wb_sel;
    wire        eq, lt, ltu;

    control_unit u_ctl (
        .clk(clk), .rst(rst),
        .is_lui(is_lui), .is_auipc(is_auipc), .is_jal(is_jal), .is_jalr(is_jalr),
        .is_branch(is_branch), .is_load(is_load), .is_store(is_store),
        .is_op_imm(is_op_imm), .is_op(is_op), .illegal(illegal),
        .funct3(funct3), .funct7_5(funct7[5]),
        .eq(eq), .lt(lt), .ltu(ltu),
        .stall(stall), .pc_load(pc_load), .target_sel_alu(target_sel_alu),
        .alu_a_sel_pc(alu_a_sel_pc), .alu_b_sel_imm(alu_b_sel_imm),
        .alu_op(alu_op), .rf_we(rf_we), .wb_sel(wb_sel),
        .mem_we(mem_we), .mem_re(mem_re), .halted(halted)
    );

    wire [31:0] pc, pc_plus4;
    wire [31:0] rs1_data, rs2_data, alu_result, wb_data;

    wire [31:0] pc_imm = pc + imm;   // branch / JAL target

    wire [31:0] alu_a = alu_a_sel_pc  ? pc  : rs1_data;
    wire [31:0] alu_b = alu_b_sel_imm ? imm : rs2_data;

    cpu_alu u_alu (
        .a(alu_a), .b(alu_b), .op(alu_op),
        .result(alu_result), .eq(eq), .lt(lt), .ltu(ltu)
    );

    cpu_prog_counter u_pc (
        .clk(clk), .rst(rst), .stall(stall), .load(pc_load),
        .target(target_sel_alu ? alu_result : pc_imm),
        .pc(pc), .pc_plus4(pc_plus4)
    );

    reg [31:0] wb_mux;
    always @* begin
        case (wb_sel)
            2'b00:   wb_mux = alu_result;
            2'b01:   wb_mux = bus_rdata;
            2'b10:   wb_mux = imm;
            default: wb_mux = pc_plus4;
        endcase
    end
    assign wb_data = wb_mux;

    cpu_reg_file u_rf (
        .clk(clk), .we(rf_we),
        .rs1_addr(rs1), .rs2_addr(rs2), .rd_addr(rd), .rd_data(wb_data),
        .rs1_data(rs1_data), .rs2_data(rs2_data)
    );

    assign imem_addr = pc;
    assign bus_addr  = alu_result;
    assign bus_wdata = rs2_data;
    assign bus_we    = mem_we;
    assign bus_re    = mem_re;
endmodule