// reg_file.v -- RV32I register file: x0..x31, 32 bits, x0 is always 0.
// Two asynchronous read ports, one synchronous write port.
// No reset loop, so it maps cleanly to FPGA memory/LUT RAM.
module cpu_reg_file (
    input         clk,
    input         we,
    input  [4:0]  rs1_addr,
    input  [4:0]  rs2_addr,
    input  [4:0]  rd_addr,
    input  [31:0] rd_data,
    output [31:0] rs1_data,
    output [31:0] rs2_data
);
    reg [31:0] regs [1:31];   // x0 is not stored

    integer i;
    initial for (i = 1; i < 32; i = i + 1) regs[i] = 32'b0;  // simulation only

    assign rs1_data = (rs1_addr == 5'd0) ? 32'b0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'b0 : regs[rs2_addr];

    always @(posedge clk)
        if (we && rd_addr != 5'd0)
            regs[rd_addr] <= rd_data;
endmodule