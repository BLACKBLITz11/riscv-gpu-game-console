`timescale 1ns/1ps
module tb_stall;
    reg         clk = 0;
    reg         rst;
    reg  [31:0] instruction;
    wire        done, halted;
    wire        mem_req, mem_we;
    wire [9:0]  mem_addr;
    wire [31:0] mem_wdata;
    reg  [31:0] mem_rdata;
    reg         mem_grant;

    integer errors = 0;

    shader_core uut (
        .clk(clk), .rst(rst), .instruction(instruction),
        .done(done), .halted(halted),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_grant(mem_grant)
    );

    always #5 clk = ~clk;

    function [31:0] make_i(input [5:0] op, input [3:0] rd, input [3:0] rs1, input [17:0] imm);
        make_i = {op, rd, rs1, imm};
    endfunction
    localparam OP_LDR = 19;

    // mock arbiter: deliberately withholds grant for the first 3 requesting
    // cycles, to simulate another "higher priority" core winning first
    integer req_cycle_count = 0;
    always @(posedge clk) begin
        if (mem_req) begin
            req_cycle_count <= req_cycle_count + 1;
            if (req_cycle_count >= 3)
                mem_grant <= 1;
            else
                mem_grant <= 0;
        end
        else begin
            req_cycle_count <= 0;
            mem_grant <= 0;
        end
    end

    initial begin
        rst = 1; instruction = 32'h0; mem_rdata = 32'h0; mem_grant = 0;
        @(negedge clk); rst = 0;

        mem_rdata = 32'h77777777;
        instruction = make_i(OP_LDR, 4'd5, 4'd0, 18'd79); // LDR R5, [R0+79] (>=LOCAL_SIZE -> global path, exercises the arbiter)

        // mid-stall check: grant isn't asserted until the 3rd requesting
        // cycle (see mock arbiter above), so at cycle 6 the core is still
        // sitting in MEMORY waiting. PC only advances at WRITEBACK, so it
        // must still be sitting at this instruction's own address (0).
        repeat (6) @(posedge clk);
        #1;
        if (uut.pc_inst.pc !== 8'h0) begin
            $display("FAIL: PC not held during stall -- pc=%0d (expected 0)", uut.pc_inst.pc);
            errors = errors + 1;
        end else begin
            $display("PASS: PC correctly frozen during stall -- pc=%0d", uut.pc_inst.pc);
        end

        repeat (9) @(posedge clk);
        #1;

        if (uut.rf_inst.registers[5] !== 32'h77777777) begin
            $display("FAIL: LDR did not complete correctly despite grant delay -- got 0x%h", uut.rf_inst.registers[5]);
            errors = errors + 1;
        end else begin
            $display("PASS: LDR correctly waited through a delayed grant and completed -- 0x%h", uut.rf_inst.registers[5]);
        end

        if (errors == 0)
            $display("\n=== ALL TESTS PASSED ===");
        else
            $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end
endmodule