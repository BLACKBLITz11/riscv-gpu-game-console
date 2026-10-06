`timescale 1ns/1ps
module tb_reg_file2;
    reg         clk = 0;
    reg         rst;
    reg         we;
    reg  [3:0]  r_addr1, r_addr2, w_addr;
    reg  [31:0] w_data;
    wire [31:0] r_data1, r_data2;

    integer errors = 0;

    reg_file uut (.clk(clk), .rst(rst), .we(we), .r_addr1(r_addr1), .r_addr2(r_addr2),
                   .w_addr(w_addr), .w_data(w_data), .r_data1(r_data1), .r_data2(r_data2));

    always #5 clk = ~clk;

    task check(input [255:0] name, input [31:0] got, input [31:0] expected);
        begin
            if (got !== expected) begin
                $display("FAIL: %s -- got %0d, expected %0d", name, got, expected);
                errors = errors + 1;
            end else begin
                $display("PASS: %s -- %0d", name, got);
            end
        end
    endtask

    initial begin
        rst = 1; we = 0; w_addr = 0; w_data = 0; r_addr1 = 0; r_addr2 = 0;

        // apply hardware reset for one clock edge
        @(negedge clk);
        rst = 0;
        r_addr1 = 4'd7;
        #1; check("reg7 zero after hardware reset", r_data1, 32'h0);

        // write a value into register 7
        @(negedge clk);
        we = 1; w_addr = 4'd7; w_data = 32'hCAFEF00D;
        @(negedge clk);
        we = 0;
        r_addr1 = 4'd7;
        #1; check("write/read reg7", r_data1, 32'hCAFEF00D);

        // now assert rst again -- this must clear it back to 0
        @(negedge clk);
        rst = 1;
        @(negedge clk);
        rst = 0;
        r_addr1 = 4'd7;
        #1; check("reg7 cleared after mid-run reset", r_data1, 32'h0);

        // reset should take priority even if we is also high
        @(negedge clk);
        we = 1; w_addr = 4'd3; w_data = 32'hABCD1234;
        @(negedge clk); // this write lands normally
        we = 1; rst = 1; w_addr = 4'd3; w_data = 32'hFFFFFFFF; // both high at once
        @(negedge clk);
        we = 0; rst = 0;
        r_addr1 = 4'd3;
        #1; check("reset takes priority over simultaneous write", r_data1, 32'h0);

        if (errors == 0)
            $display("\n=== ALL TESTS PASSED ===");
        else
            $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end
endmodule