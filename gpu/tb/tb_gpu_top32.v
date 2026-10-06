`timescale 1ns/1ps
module tb_gpu_top32;
    reg         clk = 0;
    reg         rst;
    reg  [31:0] instruction;
    wire        all_done;

    integer errors = 0;
    integer k;

    gpu_top #(.N_CORES(32)) uut (.clk(clk), .rst(rst), .instruction(instruction), .all_done(all_done));

    always #5 clk = ~clk;

    localparam OP_MOVI=21, OP_STR=20, OP_HALT=22;
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

        issue_all(make_i(OP_MOVI, 4'd1, 4'd0, 18'd99), 60);

        issue_all(make_i(OP_STR, 4'd1, 4'd0, 18'd150), 120);
        issue_all(make_i(OP_MOVI, 4'd9, 4'd0, 18'd0), 60);

        if (uut.mem.mem[150] !== 32'd99) begin
            $display("FAIL: mem[150] after 32-core simultaneous contention -- got %0d", uut.mem.mem[150]);
            errors = errors + 1;
        end else begin
            $display("PASS: mem[150] correct after real 32-core simultaneous contention -- %0d", uut.mem.mem[150]);
        end

        begin : fairness_check
            reg [31:0] grants_seen;
            grants_seen = 0;
            instruction = make_i(OP_STR, 4'd1, 4'd0, 18'd151);
            for (k = 0; k < 40; k = k + 1) begin
                @(posedge clk); #1;
                grants_seen = grants_seen | uut.mem_grant;
            end
            if (grants_seen !== 32'hFFFFFFFF) begin
                $display("FAIL: not all 32 cores granted during contention -- saw %b", grants_seen);
                errors = errors + 1;
            end else begin
                $display("PASS: all 32 cores granted fairly during real contention");
            end
        end
        instruction = make_i(OP_MOVI, 4'd9, 4'd0, 18'd0);
        repeat(60) @(posedge clk); #1;

        issue_all(make_i(OP_HALT, 4'd0, 4'd0, 18'd0), 30);

        if (all_done !== 1'b1) begin
            $display("FAIL: all_done not asserted after all 32 cores halted");
            errors = errors + 1;
        end else begin
            $display("PASS: all_done correctly asserted once all 32 cores halted");
        end

        if (errors == 0)
            $display("\n=== ALL TESTS PASSED ===");
        else
            $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end
endmodule