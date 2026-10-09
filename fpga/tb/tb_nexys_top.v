`timescale 1ns/1ps
// Smoke test for the board wrapper: loader finishes, VGA sync runs, nothing is X.
// Run from the repo root.
module tb_nexys_top;
    reg clk100 = 0, resetn = 0;
    always #5 clk100 = ~clk100;
    wire hs, vs;
    wire [3:0] r, g, b;
    nexys_top dut (.CLK100MHZ(clk100), .CPU_RESETN(resetn),
        .BTNL(1'b0), .BTNR(1'b0), .BTNC(1'b0), .BTNU(1'b0), .BTND(1'b0), .SW(2'b00),
        .VGA_HS(hs), .VGA_VS(vs), .VGA_R(r), .VGA_G(g), .VGA_B(b));
    defparam dut.core.CPU_HEX = "fpga/game.hex";
    defparam dut.core.GPU_HEX = "gpu/sw/entity_update.hex";

    integer hs_edges = 0, errors = 0;
    always @(posedge hs) hs_edges = hs_edges + 1;

    initial begin
        #200 resetn = 1;
        #200000;                              // 200 us = 8000 pixel clocks
        $display("hsync pulses: %0d, loader done: %b, outputs: hs=%b vs=%b rgb=%h%h%h",
                 hs_edges, dut.core.ld_done, hs, vs, r, g, b);
        if (hs_edges < 5) begin errors = errors + 1; $display("FAIL: hsync is not running"); end
        if (dut.core.ld_done !== 1'b1) begin errors = errors + 1; $display("FAIL: GPU program loader did not finish"); end
        if (^{hs, vs, r, g, b} === 1'bx) begin errors = errors + 1; $display("FAIL: unknown (X) values on VGA pins"); end
        if (errors == 0) $display("=== ALL TESTS PASSED ===");
        else             $display("=== FAILED ===");
        $finish;
    end
endmodule