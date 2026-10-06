module alu (
    input  [5:0]  op,       // operation selector (= opcode[5:0] directly)
    input  [31:0] a,        // first operand (rs1)
    input  [31:0] b,        // second operand (rs2)
    output reg [31:0] result,     // result for R-type ops
    output reg         zero_flag,  // set by CMP: a == b
    output reg         greater_flag, // set by CMP: a > b
    output reg         less_flag    // set by CMP: a < b
);

    // opcodes (must match the ISA table exactly)
    localparam ADD  = 6'b000000;
    localparam SUB  = 6'b000001;
    localparam MUL  = 6'b000010;
    localparam DIV  = 6'b000011;
    localparam MOD  = 6'b000100;
    localparam AND  = 6'b000101;
    localparam OR   = 6'b000110;
    localparam XOR  = 6'b000111;
    localparam NAND = 6'b001000;
    localparam NOR  = 6'b001001;
    localparam XNOR = 6'b001010;
    localparam NOT  = 6'b001011;
    localparam SHL  = 6'b001100;
    localparam SHR  = 6'b001101;
    localparam CMP  = 6'b001110;

    always @(*) begin
        // defaults every cycle -- avoids accidental latches
        result       = 32'h0;
        zero_flag    = 1'b0;
        greater_flag = 1'b0;
        less_flag    = 1'b0;

        case (op)
            ADD:  result = a + b;
            SUB:  result = a - b;
            MUL:  result = a * b;
            DIV:  result = (b == 32'h0) ? 32'h0 : a / b;   // guard divide-by-zero
            MOD:  result = (b == 32'h0) ? 32'h0 : a % b;   // guard divide-by-zero
            AND:  result = a & b;
            OR:   result = a | b;
            XOR:  result = a ^ b;
            NAND: result = ~(a & b);
            NOR:  result = ~(a | b);
            XNOR: result = ~(a ^ b);
            NOT:  result = ~a;                              // unary -- b unused
            SHL:  result = a << b;
            SHR:  result = a >> b;
            CMP: begin
                result       = 32'h0;      // CMP writes no register result
                zero_flag    = (a == b);
                greater_flag = (a > b);
                less_flag    = (a < b);
            end
            default: result = 32'h0;       // unused opcodes (branches, LDR, etc. don't route through here)
        endcase
    end

endmodule