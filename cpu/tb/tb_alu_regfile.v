`timescale 1ns/1ps
module tb_alu_regfile;
    reg clk = 0;
    always #5 clk = ~clk;

    // ---- ALU ----
    reg  [31:0] a, b;
    reg  [3:0]  op;
    wire [31:0] y;
    wire        eq, lt, ltu;
    cpu_alu u_alu (.a(a), .b(b), .op(op), .result(y), .eq(eq), .lt(lt), .ltu(ltu));

    // ---- register file ----
    reg         we;
    reg  [4:0]  rs1, rs2, rd;
    reg  [31:0] wd;
    wire [31:0] r1, r2;
    cpu_reg_file u_rf (.clk(clk), .we(we), .rs1_addr(rs1), .rs2_addr(rs2),
                   .rd_addr(rd), .rd_data(wd), .rs1_data(r1), .rs2_data(r2));

    integer errors = 0;

    task alu_check(input [3:0] o, input [31:0] x, input [31:0] z,
                   input [31:0] expected, input [63:0] name);
        begin
            op = o; a = x; b = z; #1;
            if (y !== expected) begin
                errors = errors + 1;
                $display("FAIL %0s: got %h, expected %h", name, y, expected);
            end
        end
    endtask

    task rf_write(input [4:0] r, input [31:0] v);
        begin
            @(negedge clk); we = 1; rd = r; wd = v;
            @(negedge clk); we = 0;
        end
    endtask

    task rf_check(input [4:0] r, input [31:0] expected, input [63:0] name);
        begin
            rs1 = r; #1;
            if (r1 !== expected) begin
                errors = errors + 1;
                $display("FAIL %0s: got %h, expected %h", name, r1, expected);
            end
        end
    endtask

    initial begin
        we = 0; rs1 = 0; rs2 = 0; rd = 0; wd = 0;

        // ALU
        alu_check(4'b0000, 32'd5,        32'd7,        32'd12,       "add");
        alu_check(4'b0000, 32'hFFFFFFFF, 32'd1,        32'd0,        "addwrap");
        alu_check(4'b1000, 32'd3,        32'd5,        32'hFFFFFFFE, "sub");
        alu_check(4'b0001, 32'd1,        32'd4,        32'd16,       "sll");
        alu_check(4'b0101, 32'h80000000, 32'd4,        32'h08000000, "srl");
        alu_check(4'b1101, 32'h80000000, 32'd4,        32'hF8000000, "sra");
        alu_check(4'b0010, 32'hFFFFFFFF, 32'd1,        32'd1,        "slt");
        alu_check(4'b0011, 32'hFFFFFFFF, 32'd1,        32'd0,        "sltu");
        alu_check(4'b0100, 32'h0000F0F0, 32'h0000FF00, 32'h00000FF0, "xor");
        alu_check(4'b0110, 32'h0000F0F0, 32'h00000F0F, 32'h0000FFFF, "or");
        alu_check(4'b0111, 32'h0000FF0F, 32'h00000FF0, 32'h00000F00, "and");

        // branch flags
        a = 32'hFFFFFFFF; b = 32'd1; #1;
        if (eq !== 1'b0 || lt !== 1'b1 || ltu !== 1'b0) begin
            errors = errors + 1; $display("FAIL branch flags");
        end

        // register file
        rf_write(5'd5, 32'hDEADBEEF);
        rf_check(5'd5, 32'hDEADBEEF, "x5");
        rf_write(5'd0, 32'h12345678);
        rf_check(5'd0, 32'd0, "x0");
        rf_write(5'd31, 32'hCAFEF00D);
        rs1 = 5'd5; rs2 = 5'd31; #1;
        if (r1 !== 32'hDEADBEEF || r2 !== 32'hCAFEF00D) begin
            errors = errors + 1; $display("FAIL two-port read");
        end

        if (errors == 0) $display("PASS: all alu and reg_file checks");
        else             $display("DONE: %0d errors", errors);
        $finish;
    end
endmodule