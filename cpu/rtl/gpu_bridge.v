// gpu_bridge.v
`include "gpu_regs.vh"

module gpu_bridge #(
    parameter CORE_W = 5            // = log2(N_CORES) of gpu_top
) (
    input             clk,
    input             rst,
    // CPU side (from cpu_system)
    input             gpu_we,
    input      [7:0]  gpu_offset,
    input      [31:0] gpu_wdata,
    output reg [31:0] gpu_rdata,
    // GPU side (gpu_top ports)
    output            start,
    output            prog_we,
    output     [7:0]  prog_addr,
    output     [31:0] prog_data,
    output            host_we,
    output     [9:0]  host_addr,
    output     [31:0] host_wdata,
    output            spawn_we,
    output     [CORE_W-1:0] spawn_core,
    output     [5:0]  spawn_addr,
    output     [31:0] spawn_data,
    output            render_start,
    input             all_done,
    input             render_busy
);
    // address registers that are written first, then used when DATA is written
    reg [CORE_W-1:0] spawn_core_r;
    reg [5:0]        spawn_addr_r;
    reg [7:0]        prog_addr_r;

    always @(posedge clk) begin
        if (rst) begin
            spawn_core_r <= 0;
            spawn_addr_r <= 0;
            prog_addr_r  <= 0;
        end else if (gpu_we) begin
            if (gpu_offset == `GPU_SPAWN_CORE) spawn_core_r <= gpu_wdata[CORE_W-1:0];
            if (gpu_offset == `GPU_SPAWN_ADDR) spawn_addr_r <= gpu_wdata[5:0];
            if (gpu_offset == `GPU_PROG_ADDR)  prog_addr_r  <= gpu_wdata[7:0];
        end
    end

    // one-cycle pulses, straight from the CPU's store cycle
    wire wr_host_lo = gpu_we & (gpu_offset[7:4] == 4'h0);  // offsets 0x00..0x0C
    wire wr_slots   = gpu_we & (gpu_offset >= `GPU_SHOT0_X) & (gpu_offset <= `GPU_SHOT3_Y);
    wire wr_host    = wr_host_lo | wr_slots;
    wire wr_start  = gpu_we & (gpu_offset == `GPU_START)      & gpu_wdata[0];
    wire wr_render = gpu_we & (gpu_offset == `GPU_RENDER)     & gpu_wdata[0];
    wire wr_spawn  = gpu_we & (gpu_offset == `GPU_SPAWN_DATA);
    wire wr_prog   = gpu_we & (gpu_offset == `GPU_PROG_DATA);

    assign host_we      = wr_host;
    wire [7:0] slot_rel = gpu_offset - `GPU_SHOT0_X;
    assign host_addr    = wr_slots ? (10'd2 + {2'b0, slot_rel[7:2]})   // shot slots: host words 2..9
                                   : {8'b0, gpu_offset[3:2]};          // player/shot 0: host words 0..3
    assign host_wdata   = gpu_wdata;
    assign start        = wr_start;
    assign render_start = wr_render;

    assign spawn_we     = wr_spawn;
    assign spawn_core   = spawn_core_r;
    assign spawn_addr   = spawn_addr_r;
    assign spawn_data   = gpu_wdata;

    assign prog_we      = wr_prog;
    assign prog_addr    = prog_addr_r;
    assign prog_data    = gpu_wdata;

    // sticky flag: the GPU silently ignores some writes (contract section 5)
    wire idle_ok = all_done & ~render_busy;
    wire dropped_now = ((wr_host | wr_prog) & ~all_done) |
                       ((wr_start | wr_spawn | wr_render) & ~idle_ok);
    wire clear_dropped = gpu_we & (gpu_offset == `GPU_STATUS);

    reg dropped;
    always @(posedge clk) begin
        if (rst | clear_dropped) dropped <= 1'b0;
        else if (dropped_now)    dropped <= 1'b1;
    end

    // reads: only STATUS returns data
    always @* begin
        if (gpu_offset == `GPU_STATUS)
            gpu_rdata = {29'b0, dropped, render_busy, all_done};
        else
            gpu_rdata = 32'b0;
    end
endmodule