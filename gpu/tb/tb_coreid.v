`timescale 1ns/1ps
module tb_coreid #(parameter ID = 7);
    reg         clk = 0;
    reg         rst, we;
    reg  [3:0]  r_addr1, r_addr2, w_addr;
    reg  [31:0] w_data;
    wire [31:0] r_data1, r_data2;
    integer errors = 0;

    reg_file #(.CORE_ID(ID)) uut (
        .clk(clk), .rst(rst), .we(we),
        .r_addr1(r_addr1), .r_addr2(r_addr2),
        .w_addr(w_addr), .w_data(w_data),
        .r_data1(r_data1), .r_data2(r_data2)
    );

    always #5 clk = ~clk;

    initial begin
        rst = 1; we = 0; r_addr1 = 0; r_addr2 = 0; w_addr = 0; w_data = 0;
        @(negedge clk); rst = 0;

        r_addr1 = 4'd15;
        #1;
        if (r_data1 !== ID) begin
            $display("FAIL [ID=%0d]: R15 not initialized to core ID -- got %0d", ID, r_data1);
            errors = errors + 1;
        end else $display("PASS [ID=%0d]: R15 correctly initialized to %0d", ID, r_data1);

        @(negedge clk);
        we = 1; w_addr = 4'd15; w_data = 32'hFFFFFFFF;
        @(negedge clk);
        we = 0;
        r_addr1 = 4'd15;
        #1;
        if (r_data1 !== ID) begin
            $display("FAIL [ID=%0d]: R15 was overwritten -- got %0d", ID, r_data1);
            errors = errors + 1;
        end else $display("PASS [ID=%0d]: R15 correctly protected from overwrite -- still %0d", ID, r_data1);

        @(negedge clk);
        we = 1; w_addr = 4'd3; w_data = 32'd123;
        @(negedge clk);
        we = 0;
        r_addr1 = 4'd3;
        #1;
        if (r_data1 !== 32'd123) begin
            $display("FAIL [ID=%0d]: normal register write broken", ID);
            errors = errors + 1;
        end else $display("PASS [ID=%0d]: normal registers still writable -- R3=%0d", ID, r_data1);

        if (errors == 0)
            $display("=== ID=%0d: ALL TESTS PASSED ===\n", ID);
        else
            $display("=== ID=%0d: %0d TEST(S) FAILED ===\n", ID, errors);

        $finish;
    end
endmodule