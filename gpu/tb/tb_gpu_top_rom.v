`timescale 1ns/1ps
module tb_gpu_top_rom;
    reg clk = 0;
    reg rst;
    wire all_done;
    integer errors = 0;
    integer k;

    gpu_top #(.N_CORES(4)) uut (.clk(clk), .rst(rst), .start(1'b0), .all_done(all_done),
        .prog_we(1'b0), .prog_addr(8'b0), .prog_data(32'b0),
        .host_we(1'b0), .host_addr(10'b0), .host_wdata(32'b0));

    // generate-scope indexes must be constant, so peek via a generate loop
    wire [31:0] lm0 [0:3];
    genvar g;
    generate for (g = 0; g < 4; g = g + 1) begin : peek
        assign lm0[g] = uut.cores[g].core_inst.local_mem[0];
    end endgenerate

    always #5 clk = ~clk;

    localparam OP_ADD=0, OP_STR=20, OP_MOVI=21, OP_HALT=22;
    function [31:0] make_r(input [5:0] op, input [3:0] rd, input [3:0] rs1, input [3:0] rs2);
        make_r = {op, rd, rs1, rs2, 14'b0};
    endfunction
    function [31:0] make_i(input [5:0] op, input [3:0] rd, input [3:0] rs1, input [17:0] imm);
        make_i = {op, rd, rs1, imm};
    endfunction

    initial begin
        for (k = 0; k < 256; k = k + 1) uut.instr_rom[k] = make_i(OP_HALT,0,0,0);
        uut.instr_rom[0] = make_i(OP_MOVI, 4'd1, 4'd0, 18'd7);
        uut.instr_rom[1] = make_r(OP_ADD,  4'd2, 4'd1, 4'd15);   // R2 = 7 + core id
        uut.instr_rom[2] = make_i(OP_STR,  4'd2, 4'd0, 18'd0);   // local_mem[0] = R2
        uut.instr_rom[3] = make_i(OP_HALT, 4'd0, 4'd0, 18'd0);

        rst = 1; repeat (3) @(posedge clk); rst = 0;
        repeat (200) @(posedge clk);

        if (!all_done) begin $display("FAIL: all_done not asserted"); errors = errors + 1; end
        else $display("PASS: all_done asserted");
        for (k = 0; k < 4; k = k + 1)
            if (lm0[k] !== 7 + k) begin
                $display("FAIL: core %0d local_mem[0]=%0d expected %0d", k, lm0[k], 7+k);
                errors = errors + 1;
            end else $display("PASS: core %0d local_mem[0]=%0d", k, lm0[k]);
        if (errors == 0) $display("=== ALL TESTS PASSED ==="); else $display("=== %0d FAILED ===", errors);
        $finish;
    end
endmodule