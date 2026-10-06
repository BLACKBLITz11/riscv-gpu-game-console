`timescale 1ns/1ps
module tb_integration;
    reg clk = 0;
    reg rst;
    reg [31:0] instruction;
    wire done, halted;

    wire        c0_req, c0_we;
    wire [7:0]  c0_addr;
    wire [31:0] c0_wdata;
    wire [31:0] c0_rdata;
    wire        c0_grant;

    wire [3:0] req  = {3'b000, c0_req};
    wire [3:0] we   = {3'b000, c0_we};
    wire [3:0] grant;
    assign c0_grant = grant[0];

    integer errors = 0;

    shader_core core0 (
        .clk(clk), .rst(rst), .instruction(instruction),
        .done(done), .halted(halted),
        .mem_req(c0_req), .mem_we(c0_we), .mem_addr(c0_addr),
        .mem_wdata(c0_wdata), .mem_rdata(c0_rdata), .mem_grant(c0_grant)
    );

    mem_ctrl mc (
        .clk(clk), .rst(rst), .req(req), .we(we),
        .addr0(c0_addr), .addr1(8'h0), .addr2(8'h0), .addr3(8'h0),
        .wdata0(c0_wdata), .wdata1(32'h0), .wdata2(32'h0), .wdata3(32'h0),
        .rdata0(c0_rdata), .rdata1(), .rdata2(), .rdata3(),
        .grant(grant)
    );

    always #5 clk = ~clk;

    function [31:0] make_i(input [5:0] op, input [3:0] rd, input [3:0] rs1, input [17:0] imm);
        make_i = {op, rd, rs1, imm};
    endfunction
    function [31:0] make_r(input [5:0] op, input [3:0] rd, input [3:0] rs1, input [3:0] rs2);
        make_r = {op, rd, rs1, rs2, 14'b0};
    endfunction
    localparam OP_LDR=19, OP_STR=20, OP_MOVI=21;

    // waits for the instruction to genuinely finish (state returns to
    // FETCH), however long memory arbitration makes that take -- adds
    // NO extra edges, since that caused a phantom pipeline-overlap bug
    task issue(input [31:0] instr);
        begin
            instruction = instr;
            @(posedge clk); #1;
            while (core0.state !== 3'd0) begin
                @(posedge clk); #1;
            end
        end
    endtask

    initial begin
        rst = 1; instruction = 32'h0;
        @(negedge clk); rst = 0;

        issue(make_i(OP_MOVI, 4'd1, 4'd0, 18'd4951));
        issue(make_i(OP_STR, 4'd1, 4'd0, 18'd77));
        if (core0.rf_inst.registers[1] !== 32'd4951) begin
            $display("FAIL: MOVI R1 setup"); errors = errors + 1;
        end

        if (mc.mem[77] !== 32'd4951) begin
            $display("FAIL: mem_ctrl.mem[77] doesn't hold the STR'd value -- got %0d", mc.mem[77]);
            errors = errors + 1;
        end else begin
            $display("PASS: mem_ctrl.mem[77] correctly holds the STR'd value -- %0d", mc.mem[77]);
        end

        issue(make_i(OP_LDR, 4'd2, 4'd0, 18'd77));
        issue(make_i(OP_MOVI, 4'd3, 4'd0, 18'd1)); // one more instruction so LDR's write commits

        if (core0.rf_inst.registers[2] !== 32'd4951) begin
            $display("FAIL: real STR->LDR round trip through mem_ctrl -- got %0d, expected 4951",
                core0.rf_inst.registers[2]);
            errors = errors + 1;
        end else begin
            $display("PASS: real STR->LDR round trip through mem_ctrl -- %0d", core0.rf_inst.registers[2]);
        end

        if (errors == 0)
            $display("\n=== ALL TESTS PASSED ===");
        else
            $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end
endmodule