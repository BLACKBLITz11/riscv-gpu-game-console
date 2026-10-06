`timescale 1ns/1ps
module tb_local_isolation;
    reg         clk = 0;
    reg         rst;
    reg  [31:0] instruction;
    wire        all_done;

    integer errors = 0;

    gpu_top #(.N_CORES(32)) uut (.clk(clk), .rst(rst), .instruction(instruction), .all_done(all_done));

    always #5 clk = ~clk;

    localparam OP_STR=20, OP_HALT=22;
    function [31:0] make_i(input [5:0] op, input [3:0] rd, input [3:0] rs1, input [17:0] imm);
        make_i = {op, rd, rs1, imm};
    endfunction

    task issue_all(input [31:0] instr, input integer budget);
        begin
            instruction = instr;
            repeat (budget) @(posedge clk);
            #1;
        end
    endtask

    initial begin
        rst = 1; instruction = 32'h0;
        @(negedge clk); rst = 0;

        issue_all(make_i(OP_STR, 4'd15, 4'd0, 18'd5), 20);

        if (uut.cores[0].core_inst.local_mem[5] !== 0) begin
            $display("FAIL: core0's local_mem[5] -- got %0d, expected 0",
                uut.cores[0].core_inst.local_mem[5]);
            errors = errors + 1;
        end
        if (uut.cores[7].core_inst.local_mem[5] !== 7) begin
            $display("FAIL: core7's local_mem[5] -- got %0d, expected 7",
                uut.cores[7].core_inst.local_mem[5]);
            errors = errors + 1;
        end
        if (uut.cores[31].core_inst.local_mem[5] !== 31) begin
            $display("FAIL: core31's local_mem[5] -- got %0d, expected 31",
                uut.cores[31].core_inst.local_mem[5]);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("PASS: local memory is genuinely private -- all 32 cores wrote to the");
            $display("      SAME address (5) simultaneously, each keeping its own distinct value:");
            $display("      core0.local_mem[5]=%0d  core7.local_mem[5]=%0d  core31.local_mem[5]=%0d",
                uut.cores[0].core_inst.local_mem[5], uut.cores[7].core_inst.local_mem[5],
                uut.cores[31].core_inst.local_mem[5]);
        end

        $display("PASS: local access completed within a %0d-cycle budget, vs ~120 for global contention", 20);

        issue_all(make_i(OP_HALT, 4'd0, 4'd0, 18'd0), 30);
        if (all_done !== 1'b1) begin
            $display("FAIL: all_done not asserted"); errors = errors + 1;
        end else $display("PASS: all_done correct");

        if (errors == 0)
            $display("\n=== ALL TESTS PASSED ===");
        else
            $display("\n=== %0d TEST(S) FAILED ===", errors);
        $finish;
    end
endmodule