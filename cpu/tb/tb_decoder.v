// tb_decoder.v
`timescale 1ns/1ps
module tb_decoder;
    reg  [31:0] instr;
    wire [6:0]  opcode, funct7;
    wire [4:0]  rd, rs1, rs2;
    wire [2:0]  funct3;
    wire [31:0] imm;
    wire is_lui, is_auipc, is_jal, is_jalr, is_branch, is_load, is_store, is_op_imm, is_op, illegal;

    decoder dut (.instr(instr), .opcode(opcode), .rd(rd), .rs1(rs1), .rs2(rs2),
                 .funct3(funct3), .funct7(funct7), .imm(imm),
                 .is_lui(is_lui), .is_auipc(is_auipc), .is_jal(is_jal), .is_jalr(is_jalr),
                 .is_branch(is_branch), .is_load(is_load), .is_store(is_store),
                 .is_op_imm(is_op_imm), .is_op(is_op), .illegal(illegal));

    integer errors = 0;
    integer k;

    task check32(input [31:0] got, input [31:0] exp, input [87:0] name);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: got %h expected %h (instr %h)", name, got, exp, instr);
            end
        end
    endtask

    // encoders built from the RISC-V spec bit layouts
    function [31:0] enc_b(input [4:0] a, input [4:0] b, input [2:0] f3, input [12:0] im);
        enc_b = {im[12], im[10:5], b, a, f3, im[4:1], im[11], 7'b1100011};
    endfunction
    function [31:0] enc_j(input [4:0] d, input [20:0] im);
        enc_j = {im[20], im[10:1], im[11], im[19:12], d, 7'b1101111};
    endfunction
    function [31:0] enc_s(input [4:0] a, input [4:0] b, input [2:0] f3, input [11:0] im);
        enc_s = {im[11:5], b, a, f3, im[4:0], 7'b0100011};
    endfunction

    reg [12:0] ib;
    reg [20:0] ij;
    reg [11:0] is_;

    initial begin
        // R-type: add x3,x1,x2 and sub x3,x1,x2
        instr = 32'h002081B3; #1;
        check32({27'b0,rd}, 3, "R rd"); check32({27'b0,rs1}, 1, "R rs1"); check32({27'b0,rs2}, 2, "R rs2");
        check32({31'b0,is_op}, 1, "R is_op"); check32(imm, 0, "R imm");
        instr = 32'h402081B3; #1;
        check32({25'b0,funct7}, 32'h20, "SUB funct7");

        // I-type: addi x1,x0,5 / addi x1,x0,-1 / lw x5,8(x2)
        instr = 32'h00500093; #1; check32(imm, 5, "addi +5"); check32({31'b0,is_op_imm}, 1, "addi flag");
        instr = 32'hFFF00093; #1; check32(imm, 32'hFFFFFFFF, "addi -1");
        instr = 32'h00812283; #1; check32(imm, 8, "lw imm"); check32({31'b0,is_load}, 1, "lw flag");
        check32({27'b0,rd}, 5, "lw rd"); check32({27'b0,rs1}, 2, "lw rs1");

        // S-type: sw x5,12(x2) / sw x5,-4(x2)
        instr = 32'h00512623; #1; check32(imm, 12, "sw +12"); check32({31'b0,is_store}, 1, "sw flag");
        check32({27'b0,rs2}, 5, "sw rs2");
        instr = 32'hFE512E23; #1; check32(imm, 32'hFFFFFFFC, "sw -4");

        // B-type: beq x1,x2,+8
        instr = 32'h00208463; #1; check32(imm, 8, "beq +8"); check32({31'b0,is_branch}, 1, "beq flag");

        // U-type: lui x5,0x12345 and auipc
        instr = 32'h123452B7; #1; check32(imm, 32'h12345000, "lui imm"); check32({31'b0,is_lui}, 1, "lui flag");
        instr = 32'h12345297; #1; check32({31'b0,is_auipc}, 1, "auipc flag");

        // J-type: jal x0,+16
        instr = 32'h0100006F; #1; check32(imm, 16, "jal +16"); check32({31'b0,is_jal}, 1, "jal flag");

        // jalr x0,0(x1)
        instr = 32'h00008067; #1; check32({31'b0,is_jalr}, 1, "jalr flag");

        // illegal
        instr = 32'h00000000; #1; check32({31'b0,illegal}, 1, "illegal");

        // round-trip: random immediates through the encoders
        for (k = 0; k < 2000; k = k + 1) begin
            ib  = {$random} % 4096;  ib[0] = 1'b0;
            instr = enc_b(5'd1, 5'd2, 3'b000, ib); #1;
            check32(imm, {{19{ib[12]}}, ib}, "B round");

            ij  = {$random} % 1048576; ij[0] = 1'b0;
            instr = enc_j(5'd1, ij); #1;
            check32(imm, {{11{ij[20]}}, ij}, "J round");

            is_ = {$random} % 4096;
            instr = enc_s(5'd2, 5'd5, 3'b010, is_); #1;
            check32(imm, {{20{is_[11]}}, is_}, "S round");
        end

        if (errors == 0) $display("PASS: decoder");
        else             $display("DONE: %0d errors", errors);
        $finish;
    end
endmodule