`timescale 1ns/1ps
module tb_thread_diff;
    reg         clk = 0;
    reg         rst;
    reg  [31:0] instruction;
    wire        all_done;

    integer errors = 0;
    integer k;

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

        // Every core runs: STR mem[R15 + 0] = R15
        // Core N writes its own ID to memory address N.
        issue_all(make_i(OP_STR, 4'd15, 4'd15, 18'd0), 120);

        for (k = 0; k < 32; k = k + 1) begin
            if (uut.mem.mem[k] !== k) begin
                $display("FAIL: mem[%0d] -- got %0d, expected %0d (core %0d's own ID)",
                    k, uut.mem.mem[k], k, k);
                errors = errors + 1;
            end
        end
        if (errors == 0) begin
            $display("PASS: all 32 cores wrote THEIR OWN distinct ID to THEIR OWN distinct address");
            $display("      mem[0]=%0d mem[1]=%0d ... mem[15]=%0d ... mem[31]=%0d",
                uut.mem.mem[0], uut.mem.mem[1], uut.mem.mem[15], uut.mem.mem[31]);
        end

        issue_all(make_i(OP_HALT, 4'd0, 4'd0, 18'd0), 80);
        if (all_done !== 1'b1) begin
            $display("FAIL: all_done not asserted after halt");
            errors = errors + 1;
        end else $display("PASS: all_done still correct with CORE_ID wired in");

        if (errors == 0)
            $display("\n=== ALL TESTS PASSED ===");
        else
            $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end
endmodule