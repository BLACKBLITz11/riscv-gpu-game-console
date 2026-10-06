`timescale 1ns/1ps
module tb_shader_core;
    reg         clk = 0;
    reg         rst;
    reg  [31:0] instruction;
    wire        done, halted;
    wire        mem_req, mem_we;
    wire [9:0]  mem_addr;
    wire [31:0] mem_wdata;
    reg  [31:0] mem_rdata;
    reg         mem_grant = 1;

    integer errors = 0;

    shader_core uut (
        .start(1'b0),
        .clk(clk), .rst(rst), .instruction(instruction),
        .done(done), .halted(halted),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_grant(mem_grant),
        .host_lm_we(1'b0), .host_lm_addr(6'b0), .host_lm_wdata(32'b0),
        .host_lm_raddr(6'b0)
    );

    always #5 clk = ~clk;

    localparam OP_ADD=0, OP_CMP=14, OP_BEQ=15, OP_BNE=16, OP_BGT=17, OP_BLT=18,
               OP_LDR=19, OP_STR=20, OP_MOVI=21, OP_HALT=22;

    function [31:0] make_r(input [5:0] op, input [3:0] rd, input [3:0] rs1, input [3:0] rs2);
        make_r = {op, rd, rs1, rs2, 14'b0};
    endfunction
    function [31:0] make_i(input [5:0] op, input [3:0] rd, input [3:0] rs1, input [17:0] imm);
        make_i = {op, rd, rs1, imm};
    endfunction

    task check(input [255:0] name, input [31:0] got, input [31:0] expected);
        begin
            if (got !== expected) begin
                $display("FAIL: %s -- got %0d (0x%h), expected %0d (0x%h)", name, got, got, expected, expected);
                errors = errors + 1;
            end else begin
                $display("PASS: %s -- %0d", name, got);
            end
        end
    endtask

    // clean 5-edge instruction cycle -- exactly one pass through the FSM
    task issue5(input [31:0] instr);
        begin
            instruction = instr;
            repeat (5) @(posedge clk);
            #1;
        end
    endtask

    // background monitor -- latch DUT events whenever they actually happen
    reg jump_seen = 0;
    always @(posedge clk) if (uut.jump) jump_seen <= 1;

    initial begin
        rst = 1; instruction = 32'h0; mem_rdata = 32'h0;
        @(negedge clk); rst = 0;

        issue5(make_i(OP_MOVI, 4'd1, 4'd0, 18'd5));   // MOVI R1, 5
        issue5(make_i(OP_MOVI, 4'd2, 4'd0, 18'd3));   // MOVI R2, 3
        check("MOVI R1=5 (write committed by now)", uut.rf_inst.registers[1], 32'd5);

        issue5(make_r(OP_ADD, 4'd3, 4'd1, 4'd2));     // ADD R3, R1, R2
        check("MOVI R2=3 (write committed by now)", uut.rf_inst.registers[2], 32'd3);

        issue5(make_r(OP_CMP, 4'd0, 4'd1, 4'd2));     // CMP R1, R2 (5 vs 3)
        check("ADD R3=R1+R2", uut.rf_inst.registers[3], 32'd8);
        if (uut.flag_greater !== 1'b1) begin
            $display("FAIL: CMP set flag_greater"); errors = errors + 1;
        end else $display("PASS: CMP set flag_greater");

        issue5(make_i(OP_BGT, 4'd0, 4'd0, 18'd4));    // BGT +4

        uut.local_mem[10] = 32'hAAAA5555;             // preset local mem directly -- local path never reads mem_rdata
        issue5(make_i(OP_LDR, 4'd4, 4'd0, 18'd10));   // LDR R4, [R0+10] (local path)
        if (!jump_seen) begin
            $display("FAIL: BGT never asserted jump"); errors = errors + 1;
        end else $display("PASS: BGT asserted jump");

        issue5(make_i(OP_MOVI, 4'd6, 4'd0, 18'd291)); // MOVI R6, 291
        check("LDR loaded stubbed value", uut.rf_inst.registers[4], 32'hAAAA5555);

        issue5(make_i(OP_STR, 4'd6, 4'd0, 18'd20));   // STR mem[R0+20] = R6 (local path -- this is the only path the real design uses)
        check("MOVI R6=291 (write committed by now)", uut.rf_inst.registers[6], 32'd291);

        issue5(make_i(OP_HALT, 4'd0, 4'd0, 18'd0));   // HALT
        check("STR wrote local_mem[20] correctly", uut.local_mem[20], 32'd291);

        repeat (2) @(posedge clk); #1;
        if (halted !== 1'b1) begin
            $display("FAIL: halted not asserted after HALT"); errors = errors + 1;
        end else $display("PASS: halted asserted after HALT");

        begin : halt_check
            reg [7:0] pc_before;
            pc_before = uut.pc_inst.pc;
            repeat (10) @(posedge clk); #1;
            if (uut.pc_inst.pc !== pc_before) begin
                $display("FAIL: PC moved after HALT (was %0d, now %0d)", pc_before, uut.pc_inst.pc);
                errors = errors + 1;
            end else $display("PASS: PC frozen after HALT");
        end

        if (errors == 0)
            $display("\n=== ALL TESTS PASSED ===");
        else
            $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end
endmodule