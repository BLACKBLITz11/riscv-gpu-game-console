`timescale 1ns/1ps
module tb_local_mem;
    reg clk = 0;
    reg rst;
    reg [31:0] instruction;
    wire done, halted;
    wire mem_req, mem_we;
    wire [7:0] mem_addr;
    wire [31:0] mem_wdata;
    reg  [31:0] mem_rdata;
    reg  mem_grant = 1;

    integer errors = 0;

    shader_core #(.CORE_ID(0)) uut (
        .start(1'b0),
        .clk(clk), .rst(rst), .instruction(instruction),
        .done(done), .halted(halted),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_grant(mem_grant)
    );

    always #5 clk = ~clk;

    localparam OP_MOVI=21, OP_STR=20, OP_LDR=19;
    function [31:0] make_i(input [5:0] op, input [3:0] rd, input [3:0] rs1, input [17:0] imm);
        make_i = {op, rd, rs1, imm};
    endfunction

    task issue(input [31:0] instr);
        begin
            instruction = instr;
            @(posedge clk); #1;
            while (uut.state !== 3'd0) begin
                @(posedge clk); #1;
            end
        end
    endtask

    initial begin
        rst = 1; instruction = 32'h0; mem_rdata = 32'h0;
        @(negedge clk); rst = 0;

        issue(make_i(OP_MOVI, 4'd1, 4'd0, 18'd777));
        issue(make_i(OP_STR, 4'd1, 4'd0, 18'd10));
        if (uut.local_mem[10] !== 32'd777) begin
            $display("FAIL: local_mem[10] wrong -- got %0d", uut.local_mem[10]);
            errors = errors + 1;
        end else $display("PASS: local STR landed correctly -- local_mem[10]=%0d", uut.local_mem[10]);

        issue(make_i(OP_LDR, 4'd2, 4'd0, 18'd10));
        issue(make_i(OP_MOVI, 4'd9, 4'd0, 18'd0));
        if (uut.rf_inst.registers[2] !== 32'd777) begin
            $display("FAIL: local LDR round-trip wrong -- got %0d", uut.rf_inst.registers[2]);
            errors = errors + 1;
        end else $display("PASS: local LDR round-trip correct -- R2=%0d", uut.rf_inst.registers[2]);

        issue(make_i(OP_MOVI, 4'd3, 4'd0, 18'd555));
        issue(make_i(OP_STR, 4'd3, 4'd0, 18'd70));
        if (mem_addr !== 8'd6) begin
            $display("FAIL: global address not rebased correctly -- mem_addr=%0d, expected 6", mem_addr);
            errors = errors + 1;
        end else $display("PASS: global address correctly rebased (70 -> mem_ctrl addr 6)");

        if (errors == 0)
            $display("\n=== ALL TESTS PASSED ===");
        else
            $display("\n=== %0d TEST(S) FAILED ===", errors);
        $finish;
    end
endmodule