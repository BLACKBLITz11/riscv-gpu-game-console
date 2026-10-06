// alu.v -- RV32I ALU.
// op = {funct7[5], funct3}, so the control unit can pass the instruction bits
// straight through for R-type ops. For I-type ops (ADDI, SLTI, ANDI, ...)
// the control unit must force op[3] = 0; only SRAI uses instruction bit 30.
// For loads, stores, AUIPC, JAL/JALR address maths: use op = 4'b0000 (ADD).
//
// eq / lt / ltu are always computed from a and b, for branch decisions.
module cpu_alu (
    input      [31:0] a,
    input      [31:0] b,
    input      [3:0]  op,
    output reg [31:0] result,
    output            eq,
    output            lt,    // signed   a < b
    output            ltu    // unsigned a < b
);
    wire [4:0] shamt = b[4:0];

    always @* begin
        case (op)
            4'b0000: result = a + b;                          // ADD
            4'b1000: result = a - b;                          // SUB
            4'b0001: result = a << shamt;                     // SLL
            4'b0010: result = {31'b0, $signed(a) < $signed(b)}; // SLT
            4'b0011: result = {31'b0, a < b};                 // SLTU
            4'b0100: result = a ^ b;                          // XOR
            4'b0101: result = a >> shamt;                     // SRL
            4'b1101: result = $signed(a) >>> shamt;           // SRA
            4'b0110: result = a | b;                          // OR
            4'b0111: result = a & b;                          // AND
            default: result = 32'b0;
        endcase
    end

    assign eq  = (a == b);
    assign lt  = ($signed(a) < $signed(b));
    assign ltu = (a < b);
endmodule