// nexys_top.v -- board wrapper: 100 MHz in, 40 MHz console clock out of an MMCM.
// Port names follow the Nexys 4 DDR / Nexys A7 Master XDC; rename them to match
// the XDC of the actual board once you have it.
module nexys_top (
    input        CLK100MHZ,
    input        CPU_RESETN,                    // active-low reset button
    input        BTNL, BTNR, BTNC, BTNU, BTND,
    input  [1:0] SW,
    output       VGA_HS, VGA_VS,
    output [3:0] VGA_R, VGA_G, VGA_B
);
    wire clkfb, clkfb_buf, clk40_raw, clk40, locked;

    MMCME2_BASE #(
        .CLKIN1_PERIOD(10.0),
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(8.0),       // VCO = 100 MHz x 8 = 800 MHz
        .CLKOUT0_DIVIDE_F(20.0)      // 800 MHz / 20 = 40 MHz
    ) mmcm (
        .CLKIN1(CLK100MHZ), .CLKFBIN(clkfb_buf), .CLKFBOUT(clkfb),
        .CLKOUT0(clk40_raw), .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0));
    BUFG fb_buf  (.I(clkfb),     .O(clkfb_buf));
    BUFG clk_buf (.I(clk40_raw), .O(clk40));

    // hold the console in reset until the clock is stable and the button is released
    wire rst = ~CPU_RESETN | ~locked;

    console_top #(.N_CORES(32), .CPU_HEX("game.hex"), .GPU_HEX("entity_update.hex"), .SIM_FAST(0)) core (
        .clk(clk40), .rst(rst),
        .btnl(BTNL), .btnr(BTNR), .btnc(BTNC), .btnu(BTNU), .btnd(BTND), .sw(SW),
        .vga_hs(VGA_HS), .vga_vs(VGA_VS), .vga_r(VGA_R), .vga_g(VGA_G), .vga_b(VGA_B));
endmodule