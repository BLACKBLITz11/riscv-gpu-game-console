// cpu_system.v
// 0x0000_0xxx  data RAM
// 0x4000_00xx  GPU registers (exposed as a simple bus for gpu_bridge)
// 0x4000_0100  controller buttons (read only)
module cpu_system #(
    parameter INIT_FILE = ""
) (
    input         clk,
    input         rst,
    input  [7:0]  buttons,       // bit0 up, 1 down, 2 left, 3 right, 4 fire
    output        gpu_we,
    output        gpu_re,
    output [7:0]  gpu_offset,
    output [31:0] gpu_wdata,
    input  [31:0] gpu_rdata,
    output        halted
);
    wire [31:0] imem_addr, imem_data;
    wire [31:0] bus_addr, bus_wdata, bus_rdata, ram_rdata;
    wire        bus_we, bus_re;

    cpu_core u_core (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .bus_addr(bus_addr), .bus_wdata(bus_wdata),
        .bus_we(bus_we), .bus_re(bus_re), .bus_rdata(bus_rdata),
        .halted(halted)
    );

    imem #(.INIT_FILE(INIT_FILE)) u_imem (
        .clk(clk), .addr(imem_addr), .data(imem_data)
    );

    wire sel_gpu  = (bus_addr[31:8]  == 24'h400000);
    wire sel_ctrl = (bus_addr[31:8]  == 24'h400001);
    wire sel_ram  = (bus_addr[31:12] == 20'h00000);

    dmem u_dmem (
        .clk(clk), .we(bus_we & sel_ram),
        .addr(bus_addr), .wdata(bus_wdata), .rdata(ram_rdata)
    );

    assign gpu_we     = bus_we & sel_gpu;
    assign gpu_re     = bus_re & sel_gpu;
    assign gpu_offset = bus_addr[7:0];
    assign gpu_wdata  = bus_wdata;

    assign bus_rdata = sel_gpu  ? gpu_rdata :
                       sel_ctrl ? {24'b0, buttons} : ram_rdata;
endmodule