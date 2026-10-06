`timescale 1ns/1ps
module tb_alu;
    reg  [5:0]  op;
    reg  [31:0] a, b;
    wire [31:0] result;
    wire zero_flag, greater_flag, less_flag;

    integer errors = 0;

    alu uut (.op(op), .a(a), .b(b), .result(result),
              .zero_flag(zero_flag), .greater_flag(greater_flag), .less_flag(less_flag));

    task check(input [255:0] name, input [31:0] got, input [31:0] expected);
        begin
            if (got !== expected) begin
                $display("FAIL: %s -- got %0d (0x%0h), expected %0d (0x%0h)", name, got, got, expected, expected);
                errors = errors + 1;
            end else begin
                $display("PASS: %s -- %0d", name, got);
            end
        end
    endtask

    initial begin
        a = 32'd20; b = 32'd6;

        op = 6'b000000; #1; check("ADD", result, 26);
        op = 6'b000001; #1; check("SUB", result, 14);
        op = 6'b000010; #1; check("MUL", result, 120);
        op = 6'b000011; #1; check("DIV", result, 3);
        op = 6'b000100; #1; check("MOD", result, 2);
        op = 6'b000101; #1; check("AND", result, (20 & 6));
        op = 6'b000110; #1; check("OR",  result, (20 | 6));
        op = 6'b000111; #1; check("XOR", result, (20 ^ 6));
        op = 6'b001000; #1; check("NAND", result, ~(20 & 6));
        op = 6'b001001; #1; check("NOR",  result, ~(20 | 6));
        op = 6'b001010; #1; check("XNOR", result, ~(20 ^ 6));
        op = 6'b001011; #1; check("NOT (a only)", result, ~a);
        op = 6'b001100; b = 32'd2; #1; check("SHL", result, (20 << 2));
        op = 6'b001101; #1; check("SHR", result, (20 >> 2));

        // CMP checks
        op = 6'b001110; a = 32'd5; b = 32'd5; #1;
        if (zero_flag !== 1'b1) begin $display("FAIL: CMP zero_flag"); errors=errors+1; end
        else $display("PASS: CMP zero_flag");

        a = 32'd9; b = 32'd5; #1;
        if (greater_flag !== 1'b1) begin $display("FAIL: CMP greater_flag"); errors=errors+1; end
        else $display("PASS: CMP greater_flag");

        a = 32'd2; b = 32'd5; #1;
        if (less_flag !== 1'b1) begin $display("FAIL: CMP less_flag"); errors=errors+1; end
        else $display("PASS: CMP less_flag");

        // divide-by-zero guard
        op = 6'b000011; a = 32'd50; b = 32'd0; #1;
        check("DIV by zero guarded", result, 0);
        op = 6'b000100; #1;
        check("MOD by zero guarded", result, 0);

        if (errors == 0)
            $display("\n=== ALL TESTS PASSED ===");
        else
            $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end
endmodule