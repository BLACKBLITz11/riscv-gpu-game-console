// tb_prog_counter.v
`timescale 1ns/1ps
module tb_prog_counter;
    reg clk = 0;
    always #5 clk = ~clk;

    reg rst, stall, load;
    reg [31:0] target;
    wire [31:0] pc, pc_plus4;

    cpu_prog_counter dut (.clk(clk), .rst(rst), .stall(stall), .load(load),
                      .target(target), .pc(pc), .pc_plus4(pc_plus4));

    integer errors = 0;

    task expect_pc(input [31:0] exp, input [79:0] name);
        begin
            if (pc !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: pc=%h expected %h", name, pc, exp);
            end
        end
    endtask

    task tick;
        begin @(posedge clk); #1; end
    endtask

    initial begin
        rst = 1; stall = 0; load = 0; target = 0;
        tick; tick;
        expect_pc(32'h0, "reset");

        rst = 0;
        tick; expect_pc(32'h4, "inc1");
        tick; expect_pc(32'h8, "inc2");

        stall = 1;
        tick; tick;
        expect_pc(32'h8, "stall hold");

        load = 1; target = 32'h100;
        tick;
        expect_pc(32'h8, "stall beats load");

        stall = 0;
        tick; expect_pc(32'h100, "load");

        target = 32'h203;
        tick; expect_pc(32'h200, "low bits cleared");

        load = 0;
        tick; expect_pc(32'h204, "inc after load");

        stall = 1; rst = 1;
        tick; expect_pc(32'h0, "reset beats stall");

        if (errors == 0) $display("PASS: prog_counter");
        else             $display("DONE: %0d errors", errors);
        $finish;
    end
endmodule