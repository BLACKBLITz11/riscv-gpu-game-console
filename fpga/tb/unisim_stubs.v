`timescale 1ns/1ps
// Simulation stand-ins for the Xilinx primitives (NOT used in Vivado).
module BUFG (input I, output O);
    assign O = I;
endmodule

module MMCME2_BASE #(
    parameter CLKIN1_PERIOD = 10.0, parameter DIVCLK_DIVIDE = 1,
    parameter CLKFBOUT_MULT_F = 8.0, parameter CLKOUT0_DIVIDE_F = 20.0
) (
    input CLKIN1, input CLKFBIN, input PWRDWN, input RST,
    output CLKFBOUT, output CLKOUT0, output reg LOCKED
);
    reg c = 0;
    always #12.5 c = ~c;                 // 40 MHz
    assign CLKOUT0 = c;
    assign CLKFBOUT = CLKIN1;
    initial begin LOCKED = 0; #2000 LOCKED = 1; end
endmodule