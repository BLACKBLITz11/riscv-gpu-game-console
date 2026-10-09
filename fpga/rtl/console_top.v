// console_top.v -- the whole console on one 40 MHz clock:
//   CPU + bridge + GPU (+ framebuffer) + VGA scan-out + GPU program loader.
module console_top #(
    parameter N_CORES = 32,
    parameter GPU_HEX = "entity_update.hex",   // GPU program (from entity_update.asm)
    parameter SIM_FAST = 0                     // 1 = simulation only: a frame every 8192 clocks
    parameter GPU_HEX = "entity_update.hex"    // GPU program (from entity_update.asm)
) (
    input        clk,          // 40 MHz
    input        rst,          // active high (asynchronous button)
    input        btnl, btnr, btnc, btnu, btnd,
    input  [1:0] sw,
    output       vga_hs, vga_vs,
    output [3:0] vga_r, vga_g, vga_b
);
    localparam CORE_W = (N_CORES <= 1) ? 1 : $clog2(N_CORES);

    // ---- reset: power-on hold + synchronised button ----
    reg [3:0] por = 4'd0;
    always @(posedge clk) if (!(&por)) por <= por + 4'd1;
    reg [1:0] rst_s = 2'b00;
    always @(posedge clk) rst_s <= {rst_s[0], rst};
    wire rst_int = rst_s[1] | ~(&por);

    // ---- buttons: 2-flop synchroniser, then the controller bit layout ----
    reg [6:0] b_s1 = 7'd0, b_s2 = 7'd0;
    always @(posedge clk) begin
        b_s1 <= {sw, btnu, btnc, btnr, btnl, btnd};
        b_s2 <= b_s1;
    end
    // bit0 unused, 1 restart, 2 left, 3 right, 4 fire, 5 new wave, 7:6 weapon level - 1
    wire [7:0] buttons = {b_s2, 1'b0};

    // ---- GPU program loader (CPU stays in reset until it is done) ----
    wire        ld_we, ld_done;
    wire [7:0]  ld_addr;
    wire [31:0] ld_data;
    gpu_prog_loader #(.FILE(GPU_HEX)) loader (
        .clk(clk), .rst(rst_int), .we(ld_we), .addr(ld_addr), .data(ld_data), .done(ld_done));
    wire cpu_rst = rst_int | ~ld_done;

    // ---- CPU <-> bridge <-> GPU ----
    wire        gpu_we, cpu_halted;
    wire [7:0]  gpu_offset;
    wire [31:0] gpu_wdata, gpu_rdata;
    wire [7:0]  vga_frame_count;
    reg  [12:0] fast_div = 13'd0;
    reg  [7:0]  fast_count = 8'd0;

    always @(posedge clk) begin
        fast_div <= fast_div + 13'd1;
        if (&fast_div) fast_count <= fast_count + 8'd1;
    end
    wire [7:0]  frame_count = SIM_FAST ? fast_count : vga_frame_count;

    cpu_system #(.INIT_FILE(CPU_HEX)) cpu (
        .clk(clk), .rst(cpu_rst), .buttons(buttons), .frame_count(vga_frame_count),
        .gpu_we(gpu_we), .gpu_re(), .gpu_offset(gpu_offset), .gpu_wdata(gpu_wdata),
        .gpu_rdata(gpu_rdata), .halted(cpu_halted));

    wire                start, prog_we, host_we, spawn_we, render_start;
    wire [7:0]          prog_addr;
    wire [31:0]         prog_data, host_wdata, spawn_data;
    wire [9:0]          host_addr;
    wire [CORE_W-1:0]   spawn_core;
    wire [5:0]          spawn_addr;
    wire                all_done, render_busy, render_done, fb_pixel;
    wire [7:0]          alive_count, fb_x, fb_y;

    gpu_bridge #(.CORE_W(CORE_W)) bridge (
        .clk(clk), .rst(cpu_rst),
        .gpu_we(gpu_we), .gpu_offset(gpu_offset), .gpu_wdata(gpu_wdata), .gpu_rdata(gpu_rdata),
        .start(start), .prog_we(prog_we), .prog_addr(prog_addr), .prog_data(prog_data),
        .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
        .spawn_we(spawn_we), .spawn_core(spawn_core), .spawn_addr(spawn_addr), .spawn_data(spawn_data),
        .render_start(render_start), .all_done(all_done), .render_busy(render_busy),
        .alive_count(alive_count));

    wire        g_prog_we   = prog_we | ld_we;
    wire [7:0]  g_prog_addr = ld_we ? ld_addr : prog_addr;
    wire [31:0] g_prog_data = ld_we ? ld_data : prog_data;

    gpu_top #(.N_CORES(N_CORES), .START_HALTED(1), .HAS_FB(1)) gpu (
        .clk(clk), .rst(rst_int), .start(start), .all_done(all_done),
        .prog_we(g_prog_we), .prog_addr(g_prog_addr), .prog_data(g_prog_data),
        .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
        .spawn_we(spawn_we), .spawn_core(spawn_core), .spawn_addr(spawn_addr), .spawn_data(spawn_data),
        .render_start(render_start), .render_busy(render_busy), .render_done(render_done),
        .fb_x(fb_x), .fb_y(fb_y), .fb_pixel(fb_pixel), .alive_count(alive_count));

    // ---- video + 60 Hz frame counter ----
    wire frame_tick;
    vga_scanout vga (
        .clk(clk), .rst(rst_int),
        .fb_x(fb_x), .fb_y(fb_y), .fb_pixel(fb_pixel),
        .hsync(vga_hs), .vsync(vga_vs), .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
        .frame_tick(frame_tick), .frame_count(frame_count));
endmodule