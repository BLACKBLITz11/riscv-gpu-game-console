module gpu_top #(
    parameter N_CORES      = 32,
    parameter START_HALTED = 0,  // 1 = cores wait for `start` after reset (use with the host ports)
    parameter HAS_FB       = 0,  // 1 = include the 256x256 framebuffer
    parameter CORE_W = (N_CORES <= 1) ? 1 : $clog2(N_CORES)   // derived -- do not override
) (
    input         clk,
    input         rst,
    input         start,      // 1-cycle pulse: begin next tick (ignored unless all_done and not rendering)
    output        all_done,

    // ---- program load port (writes the shared instruction ROM) ----
    // Accepted only while all_done is high, so a running core can never
    // fetch a half-written instruction. The ROM is not cleared by rst.
    input         prog_we,
    input  [7:0]  prog_addr,
    input  [31:0] prog_data,

    // ---- host write port into shared (global) memory ----
    // host_addr is in mem_ctrl's own space: 0=player_x 1=player_y
    // 2=shot_x 3=shot_y (raw ISA addresses 64..67). Accepted only while
    // all_done is high.
    input         host_we,
    input  [9:0]  host_addr,
    input  [31:0] host_wdata,

    // ---- host write port into per-core local memory (spawn / respawn) ----
    // Writes one word of core `spawn_core`'s local_mem[spawn_addr]
    // (this program: 0=pos_x 1=pos_y 2=vel_x 3=vel_y 4=alive).
    // Accepted only while all_done is high and no frame is rendering.
    input                 spawn_we,
    input  [CORE_W-1:0]   spawn_core,
    input  [5:0]          spawn_addr,
    input  [31:0]         spawn_data,

    // ---- framebuffer (only when HAS_FB=1; otherwise outputs read 0) ----
    input         render_start,   // 1-cycle pulse; ignored unless idle + all_done (and not with `start`)
    output        render_busy,
    output        render_done,    // 1-cycle pulse when the frame is complete
    input  [7:0]  fb_x,
    input  [7:0]  fb_y,
    output        fb_pixel,
    output [7:0]  alive_count   // alive entities in the last completed render (0 if HAS_FB=0)
);

    // NOTE: no dispatch_unit / thread batching here -- with N_CORES==32
    // and one thread per core (batch size 1), every thread gets its own
    // dedicated core running once, so there's no need to cycle multiple
    // groups of threads through a smaller set of cores. If N_CORES were
    // ever smaller than the thread count again, batching logic would
    // need to come back -- flagging that as the condition under which
    // this simplification would need revisiting.

    // ---- shared instruction ROM ----
    // Every thread runs the exact same entity-update program on
    // different data (SIMT-friendly workload even though each core's
    // PC is architecturally independent), so one shared ROM -- read by
    // every core at its own PC -- is the better fit here (per the build
    // plan). No arbitration is needed for this, unlike the data-memory
    // path: reads are non-destructive, so simultaneous reads from
    // different cores never conflict.
    // 8-bit PC -> 256-instruction program cap.
    // Written through the prog_* port below (older testbenches still poke it
    // hierarchically, which also works in simulation).
    reg [31:0] instr_rom [0:255];

    wire [N_CORES-1:0]        mem_req;
    wire [N_CORES-1:0]        mem_we;
    wire [N_CORES*10 - 1:0]   mem_addr_flat;
    wire [N_CORES*32 - 1:0]   mem_wdata_flat;
    wire [N_CORES*32 - 1:0]   mem_rdata_flat;
    wire [N_CORES-1:0]        mem_grant;


    wire [N_CORES-1:0] halted;
    assign all_done = &halted;

    // local_mem read path (framebuffer -> selected core)
    wire [31:0]               lm_rdata_arr [0:N_CORES-1];   // per-core read data (array, not one wide bus)
    wire [CORE_W-1:0]         fb_peek_core;
    wire [5:0]                fb_peek_addr;
    wire [31:0]               fb_peek_data = lm_rdata_arr[fb_peek_core];

    // A start pulse only takes effect when EVERY core has halted AND no frame
    // is being rendered, so it can't restart cores out of sync or change the
    // entity state a render is reading.
    wire tick = start & all_done & ~render_busy;

    // host-side writes are gated the same way
    always @(posedge clk)
        if (prog_we && all_done)
            instr_rom[prog_addr] <= prog_data;

    genvar i;
    generate
        for (i = 0; i < N_CORES; i = i + 1) begin : cores
            // combinational fetch: every core reads the shared ROM at
            // its own PC -- pure reads never conflict, so no
            // arbitration is needed here (unlike the data-memory path)
            // (per-core wires, NOT slices of one wide bus: a wide bus makes the
            // simulator re-evaluate all cores whenever any one core's fetch changes)
            wire [7:0]  pc_i;
            wire [31:0] instr_i = instr_rom[pc_i];
            wire [31:0] lm_rdata_i;
            assign lm_rdata_arr[i] = lm_rdata_i;

            shader_core #(.CORE_ID(i), .START_HALTED(START_HALTED)) core_inst (
                .clk(clk), .rst(rst), .start(tick),
                .instruction(instr_i),
                .pc(pc_i),
                .done(), .halted(halted[i]),
                .mem_req(mem_req[i]),
                .mem_we(mem_we[i]),
                .mem_addr(mem_addr_flat[i*10 +: 10]),
                .mem_wdata(mem_wdata_flat[i*32 +: 32]),
                .mem_rdata(mem_rdata_flat[i*32 +: 32]),
                .mem_grant(mem_grant[i]),
                .host_lm_we(spawn_we & all_done & ~render_busy & (spawn_core == i)),
                .host_lm_addr(spawn_addr),
                .host_lm_wdata(spawn_data),
                .host_lm_raddr(fb_peek_addr),
                .host_lm_rdata(lm_rdata_i)
            );
        end
    endgenerate

    mem_ctrl #(.N_CORES(N_CORES)) mem (
        .clk(clk), .rst(rst),
        .req(mem_req), .we(mem_we),
        .addr_flat(mem_addr_flat),
        .wdata_flat(mem_wdata_flat),
        .rdata_flat(mem_rdata_flat),
        .grant(mem_grant),
        .host_we(host_we & all_done),
        .host_addr(host_addr),
        .host_wdata(host_wdata)
    );

    generate
        if (HAS_FB) begin : fbuf
            framebuffer #(.N_CORES(N_CORES)) fb (
                .clk(clk), .rst(rst),
                .all_done(all_done),
                .render_start(render_start & ~start),
                .busy(render_busy), .done(render_done),
                .peek_core(fb_peek_core), .peek_addr(fb_peek_addr), .peek_data(fb_peek_data),
                .rd_x(fb_x), .rd_y(fb_y), .rd_pixel(fb_pixel), .alive_count(alive_count)
            );
        end else begin : nofb
            assign render_busy   = 1'b0;
            assign render_done   = 1'b0;
            assign fb_pixel      = 1'b0;
            assign alive_count   = 8'd0;
            assign fb_peek_core  = {CORE_W{1'b0}};
            assign fb_peek_addr  = 6'd0;
        end
    endgenerate

endmodule