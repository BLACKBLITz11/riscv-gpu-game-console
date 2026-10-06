`timescale 1ns/1ps
// Framebuffer test: after every tick the host pulses render_start, then ALL
// 65536 pixels are read back through fb_x/fb_y/fb_pixel and compared with an
// independent model built from the reference entity state.
// Also checks: start / spawn are ignored while a frame is rendering, and
// render_start is ignored mid-tick or when sent together with start.
// Shot slots 1..3 (global words 4..9) are parked at 1000 so they never hit.
// Run from the repo root (the hex path below is relative to it).
module tb_framebuffer;
    localparam N = 32, TICKS = 30;
    reg clk = 0, rst, start = 0, render_start = 0;
    reg         prog_we = 0;  reg [7:0]  prog_addr = 0;  reg [31:0] prog_data = 0;
    reg         host_we = 0;  reg [9:0]  host_addr = 0;  reg [31:0] host_wdata = 0;
    reg         spawn_we = 0; reg [4:0]  spawn_core = 0; reg [5:0]  spawn_addr = 0; reg [31:0] spawn_data = 0;
    reg  [7:0]  fb_x = 0, fb_y = 0;
    wire all_done, render_busy, render_done, fb_pixel;
    integer errors = 0, frames = 0, hits = 0, respawns = 0, done_count = 0, render_gate_ok = 0, tick_gate_ok = 0, both_ok = 0, mid_ok = 0;
    integer t, i, x, y, seed, cyc, k, plen_words, mism, pop, last_render_cycles;
    gpu_top #(.N_CORES(N), .START_HALTED(1), .HAS_FB(1)) uut (
        .clk(clk), .rst(rst), .start(start), .all_done(all_done),
        .prog_we(prog_we), .prog_addr(prog_addr), .prog_data(prog_data),
        .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
        .spawn_we(spawn_we), .spawn_core(spawn_core), .spawn_addr(spawn_addr), .spawn_data(spawn_data),
        .render_start(render_start), .render_busy(render_busy), .render_done(render_done),
        .fb_x(fb_x), .fb_y(fb_y), .fb_pixel(fb_pixel));
    always #5 clk = ~clk;
    always @(posedge clk) if (render_done) done_count = done_count + 1;

    task host_write(input [9:0] a, input [31:0] d);
    begin @(negedge clk); host_we = 1; host_addr = a; host_wdata = d; @(negedge clk); host_we = 0; end
    endtask
    task prog_write(input [7:0] a, input [31:0] d);
    begin @(negedge clk); prog_we = 1; prog_addr = a; prog_data = d; @(negedge clk); prog_we = 0; end
    endtask
    task spawn_write(input [4:0] c, input [5:0] a, input [31:0] d);
    begin @(negedge clk); spawn_we = 1; spawn_core = c; spawn_addr = a; spawn_data = d; @(negedge clk); spawn_we = 0; end
    endtask

    reg [31:0] prog_img [0:255];
    reg [31:0] in_px [0:N-1], in_py [0:N-1], in_vx [0:N-1], in_vy [0:N-1], in_al [0:N-1];
    reg [31:0] m_px [0:N-1], m_py [0:N-1], m_al [0:N-1];
    wire [31:0] o_px [0:N-1], o_py [0:N-1], o_al [0:N-1];
    reg exp_fb [0:65535];
    genvar g;
    generate for (g = 0; g < N; g = g + 1) begin : hook   // read-only probes
        assign o_px[g] = uut.cores[g].core_inst.local_mem[0];
        assign o_py[g] = uut.cores[g].core_inst.local_mem[1];
        assign o_al[g] = uut.cores[g].core_inst.local_mem[4];
    end endgenerate

    task spawn_entity(input integer c);
    begin
        spawn_write(c, 0, in_px[c]); spawn_write(c, 1, in_py[c]);
        spawn_write(c, 2, in_vx[c]); spawn_write(c, 3, in_vy[c]);
        spawn_write(c, 4, in_al[c]);
        m_px[c] = in_px[c]; m_py[c] = in_py[c]; m_al[c] = in_al[c];
    end
    endtask
    task random_entity(input integer c, input alive);
    begin
        in_px[c] = $random(seed) & 255;  in_py[c] = $random(seed) & 255;
        in_vx[c] = ($random(seed) % 16); in_vy[c] = ($random(seed) % 16);
        in_al[c] = alive;
    end
    endtask

    reg [31:0] sx, sy, npx, npy, ndx, ndy;
    integer tgt, tries, ox, oy, saw_busy, dc0;

    // mode 0: plain tick | 1: render_start pulsed mid-tick (must be ignored)
    //      | 2: render_start + start in the SAME cycle (tick wins, render ignored)
    task run_tick(input integer mode);
    begin
        saw_busy = 0; dc0 = done_count;
        @(negedge clk); start = 1; if (mode == 2) render_start = 1;
        @(negedge clk); start = 0; render_start = 0; #1;
        if (all_done) begin errors = errors + 1; $display("FAIL tick %0d: cores did not leave HALTED", t); end
        cyc = 0;
        while (!all_done && cyc < 20000) begin
            @(posedge clk); cyc = cyc + 1; if (render_busy) saw_busy = 1;
            if (mode == 1 && cyc == 40) begin
                @(negedge clk); render_start = 1; @(negedge clk); render_start = 0; #1;
                if (render_busy) saw_busy = 1;
            end
        end
        #1;
        if (!all_done) begin errors = errors + 1; $display("FAIL tick %0d: timeout", t); end
        if (mode != 0) begin
            if (saw_busy || done_count != dc0) begin errors = errors + 1; $display("FAIL tick %0d: render ran when it should have been ignored (mode %0d)", t, mode); end
            else if (mode == 1) mid_ok = mid_ok + 1; else both_ok = both_ok + 1;
        end
    end
    endtask

    // pulse render_start and wait for the frame; mode 1 = poke start + spawn mid-render
    task do_render(input integer mode);
    begin
        dc0 = done_count;
        @(negedge clk); render_start = 1; @(negedge clk); render_start = 0; #1;
        if (!render_busy) begin errors = errors + 1; $display("FAIL tick %0d: render did not start", t); end
        if (mode == 1) begin
            repeat (5) @(negedge clk);
            start = 1; spawn_we = 1; spawn_core = 5'd3; spawn_addr = 6'd0; spawn_data = 32'h55;
            @(negedge clk); start = 0; spawn_we = 0; #1;
            if (!all_done || o_px[3] !== m_px[3]) begin errors = errors + 1; $display("FAIL tick %0d: start/spawn accepted during render", t); end
            else render_gate_ok = render_gate_ok + 1;
        end
        cyc = 0;
        while (render_busy && cyc < 2000) begin @(posedge clk); cyc = cyc + 1; end
        #1;
        last_render_cycles = cyc;
        if (render_busy || done_count != dc0 + 1) begin errors = errors + 1; $display("FAIL tick %0d: render timeout / done pulse count", t); end
    end
    endtask

    task check_frame;
    begin
        for (i = 0; i < 65536; i = i + 1) exp_fb[i] = 1'b0;
        for (i = 0; i < N; i = i + 1) if (m_al[i]) exp_fb[{m_py[i][7:0], m_px[i][7:0]}] = 1'b1;
        mism = 0; pop = 0;
        for (y = 0; y < 256; y = y + 1)
            for (x = 0; x < 256; x = x + 1) begin
                fb_x = x; fb_y = y; #1;
                if (fb_pixel !== exp_fb[{y[7:0], x[7:0]}]) mism = mism + 1;
                if (fb_pixel === 1'b1) pop = pop + 1;
            end
        frames = frames + 1;
        if (mism != 0) begin errors = errors + 1; $display("FAIL tick %0d: frame has %0d wrong pixels", t, mism); end
    end
    endtask

    initial begin
        seed = 32'hFACADE;
        $readmemh("gpu/sw/entity_update.hex", prog_img);
        rst = 1; repeat (3) @(posedge clk); @(negedge clk); rst = 0; #1;
        if (!all_done) begin errors = errors + 1; $display("FAIL: cores not halted after reset"); end
        plen_words = 0;
        while (prog_img[plen_words] !== 32'hxxxxxxxx && plen_words < 256) plen_words = plen_words + 1;
        for (i = 0; i < plen_words; i = i + 1) prog_write(i, prog_img[i]);
        host_write(10'd2, 0); host_write(10'd3, 0); sx = 0; sy = 0;
        host_write(10'd4, 32'd1000); host_write(10'd5, 32'd1000);
        host_write(10'd6, 32'd1000); host_write(10'd7, 32'd1000);
        host_write(10'd8, 32'd1000); host_write(10'd9, 32'd1000);   // slots 1..3 parked
        for (i = 0; i < N; i = i + 1) begin random_entity(i, (i % 8 == 0) ? 1'b0 : 1'b1); spawn_entity(i); end

        // frame 0: before any tick, straight from the spawned state
        t = 0; do_render(0); check_frame;
        $display("frame of initial state: %0d lit pixels, render took %0d cycles", pop, last_render_cycles);

        for (t = 1; t <= TICKS; t = t + 1) begin
            if (t == 10 || t == 20)
                for (i = 0; i < N; i = i + 1) if (m_al[i] == 0) begin random_entity(i, 1'b1); spawn_entity(i); respawns = respawns + 1; end
            tgt = -1;
            for (tries = 0; tries < 8 && tgt < 0; tries = tries + 1) begin k = $random(seed) & 31; if (m_al[k]) tgt = k; end
            if (tgt >= 0 && ($random(seed) & 3) != 0) begin
                ox = ($random(seed) % 11); oy = ($random(seed) % 11);
                sx = (m_px[tgt] + in_vx[tgt] + ox) & 255; sy = (m_py[tgt] + in_vy[tgt] + oy) & 255;
            end else begin sx = $random(seed) & 255; sy = $random(seed) & 255; end
            host_write(10'd2, sx); host_write(10'd3, sy);

            run_tick((t == 12) ? 1 : (t == 8) ? 2 : 0);

            for (i = 0; i < N; i = i + 1) if (m_al[i]) begin       // reference model
                m_px[i] = (m_px[i] + in_vx[i]) & 255; m_py[i] = (m_py[i] + in_vy[i]) & 255;
                ndx = (m_px[i] > sx) ? m_px[i] - sx : sx - m_px[i];
                ndy = (m_py[i] > sy) ? m_py[i] - sy : sy - m_py[i];
                if (ndx <= 8 && ndy <= 8) begin m_al[i] = 0; hits = hits + 1; end
            end
            for (i = 0; i < N; i = i + 1)
                if (o_px[i] !== m_px[i] || o_py[i] !== m_py[i] || o_al[i] !== m_al[i]) begin
                    errors = errors + 1; $display("FAIL tick %0d core %0d: entity state wrong", t, i);
                end

            do_render((t == 5) ? 1 : 0);
            check_frame;
        end
        $display("ticks=%0d frames_checked=%0d (x65536 pixels) hits=%0d respawns=%0d", TICKS, frames, hits, respawns);
        if (render_gate_ok == 1) $display("PASS: start/spawn ignored while a frame renders");
        else begin errors = errors + 1; $display("FAIL: render-gating check did not run"); end
        if (mid_ok == 1 && both_ok == 1) $display("PASS: render_start ignored mid-tick and when sent with start");
        else begin errors = errors + 1; $display("FAIL: render_start ignore-checks did not run"); end
        if (errors == 0) $display("=== ALL TESTS PASSED ===");
        else $display("=== %0d FAILED ===", errors);
        $finish;
    end
endmodule