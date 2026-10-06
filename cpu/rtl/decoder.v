// decoder.v
module decoder (
    input      [31:0] instr,
    output     [6:0]  opcode,
    output     [4:0]  rd,
    output     [4:0]  rs1,
    output     [4:0]  rs2,
    output     [2:0]  funct3,
    output     [6:0]  funct7,
    output reg [31:0] imm,
    output            is_lui,
    output            is_auipc,
    output            is_jal,
    output            is_jalr,
    output            is_branch,
    output            is_load,
    output            is_store,
    output            is_op_imm,
    output            is_op,
    output            illegal
);
    localparam OP_LUI    = 7'b0110111;
    localparam OP_AUIPC  = 7'b0010111;
    localparam OP_JAL    = 7'b1101111;
    localparam OP_JALR   = 7'b1100111;
    localparam OP_BRANCH = 7'b1100011;
    localparam OP_LOAD   = 7'b0000011;
    localparam OP_STORE  = 7'b0100011;
    localparam OP_IMM    = 7'b0010011;
    localparam OP_REG    = 7'b0110011;

    assign opcode = instr[6:0];
    assign rd     = instr[11:7];
    assign funct3 = instr[14:12];
    assign rs1    = instr[19:15];
    assign rs2    = instr[24:20];
    assign funct7 = instr[31:25];

    assign is_lui    = (opcode == OP_LUI);
    assign is_auipc  = (opcode == OP_AUIPC);
    assign is_jal    = (opcode == OP_JAL);
    assign is_jalr   = (opcode == OP_JALR);
    assign is_branch = (opcode == OP_BRANCH);
    assign is_load   = (opcode == OP_LOAD);
    assign is_store  = (opcode == OP_STORE);
    assign is_op_imm = (opcode == OP_IMM);
    assign is_op     = (opcode == OP_REG);

    assign illegal = ~(is_lui | is_auipc | is_jal | is_jalr | is_branch |
                       is_load | is_store | is_op_imm | is_op);

    always @* begin
        case (opcode)
            OP_IMM, OP_LOAD, OP_JALR:   // I-type
                imm = {{20{instr[31]}}, instr[31:20]};
            OP_STORE:                   // S-type
                imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            OP_BRANCH:                  // B-type
                imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
            OP_LUI, OP_AUIPC:           // U-type
                imm = {instr[31:12], 12'b0};
            OP_JAL:                     // J-type
                imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
            default:                    // R-type and unknown
                imm = 32'b0;
        endcase
    end
endmodule