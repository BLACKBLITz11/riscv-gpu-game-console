`timescale 1ns/1ps
// Checks vga_scanout against an independent model of the screen:
//  - every output (hsync, vsync, colour) for 1.45 million clocks (a bit over 2 frames)
//    against a model that works out the expected value from the beam position
//  - measured hsync / vsync pulse widths and periods, frame_tick period, frame_count steps
module tb_vga_scanout;
    reg clk = 0, rst = 1;
    always #12.5 clk = ~clk;                      // 40 MHz

    wire [7:0] fb_x, fb_y;
    wire       hsync, vsync, frame_tick;
    wire [3:0] vga_r, vga_g, vga_b;
    wire [7:0] frame_count;

    // fake framebuffer with a registered read, like the real one:
    // pixel = x[2] ^ y[1]  (a pattern that shows if x/y or the 2x scaling were wrong)
    reg fbp;
    always @(posedge clk) fbp <= fb_x[2] ^ fb_y[1];

    vga_scanout dut (.clk(clk), .rst(rst), .fb_x(fb_x), .fb_y(fb_y), .fb_pixel(fbp),
        .hsync(hsync), .vsync(vsync), .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
        .frame_tick(frame_tick), .frame_count(frame_count));

    // ---- independent beam-position model ----
    integer cx = 0, cy = 0;
    always @(posedge clk) begin
        if (rst) begin cx <= 0; cy <= 0; end
        else if (cx == 1055) begin cx <= 0; cy <= (cy == 627) ? 0 : cy + 1; end
        else cx <= cx + 1;
    end

    integer dx, dy;
    reg e_px;
    always @(*) begin
        dx = cx - 144; dy = cy - 44;
        if (dx >= 0 && dx < 512 && dy >= 0 && dy < 512)
            e_px = (((dx / 2) >> 2) ^ ((dy / 2) >> 1)) & 1;
        else
            e_px = 1'b0;
    end

    // the outputs lag the beam position by 2 clocks
    reg e1_px, e1_hs, e1_vs, e2_px, e2_hs, e2_vs;
    always @(posedge clk) begin
        e1_px <= e_px;
        e1_hs <= (cx >= 840 && cx < 968);
        e1_vs <= (cy >= 601 && cy < 605);
        e2_px <= e1_px; e2_hs <= e1_hs; e2_vs <= e1_vs;
    end

    integer errors = 0, nchk = 0, ticks = 0;
    always @(posedge clk) if (!rst) ticks <= ticks + 1;

    always @(negedge clk) if (!rst && ticks > 10) begin
        nchk = nchk + 1;
        if (hsync !== e2_hs || vsync !== e2_vs ||
            vga_r !== {4{e2_px}} || vga_g !== {4{e2_px}} || vga_b !== {4{e2_px}}) begin
            errors = errors + 1;
            if (errors <= 5)
                $display("MISMATCH at beam (%0d,%0d): hs=%b vs=%b rgb=%h%h%h expected hs=%b vs=%b px=%b",
                         cx, cy, hsync, vsync, vga_r, vga_g, vga_b, e2_hs, e2_vs, e2_px);
        end
    end

    // ---- measured timing ----
    function near(input real v, input real target);
        near = (v > target - 0.1) && (v < target + 0.1);
    endfunction

    real t_hr = -1, t_vr = -1, t_ft = -1;
    integer hper_ok = 0, hper_bad = 0, hw_ok = 0, hw_bad = 0;
    integer vper_ok = 0, vper_bad = 0, vw_ok = 0, vw_bad = 0;
    integer fper_ok = 0, fper_bad = 0, fcnt_bad = 0;
    reg [7:0] last_fc;

    always @(posedge hsync) begin
        if (t_hr >= 0) begin
            if (near(($realtime - t_hr) / 25.0, 1056.0)) hper_ok = hper_ok + 1; else hper_bad = hper_bad + 1;
        end
        t_hr = $realtime;
    end
    always @(negedge hsync) if (t_hr >= 0) begin
        if (near(($realtime - t_hr) / 25.0, 128.0)) hw_ok = hw_ok + 1; else hw_bad = hw_bad + 1;
    end

    always @(posedge vsync) begin
        if (t_vr >= 0) begin
            if (near(($realtime - t_vr) / 25.0, 663168.0)) vper_ok = vper_ok + 1; else vper_bad = vper_bad + 1;
        end
        t_vr = $realtime;
    end
    always @(negedge vsync) if (t_vr >= 0) begin
        if (near(($realtime - t_vr) / 25.0, 4224.0)) vw_ok = vw_ok + 1; else vw_bad = vw_bad + 1;
    end

    always @(posedge clk) if (frame_tick) begin
        if (t_ft >= 0) begin
            if (near(($realtime - t_ft) / 25.0, 663168.0)) fper_ok = fper_ok + 1; else fper_bad = fper_bad + 1;
            if (frame_count !== last_fc + 8'd1) fcnt_bad = fcnt_bad + 1;
        end
        t_ft = $realtime;
        last_fc = frame_count;
    end

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat (1450000) @(posedge clk);
        @(negedge clk);

        $display("compared %0d clocks of every output against the model, %0d mismatches", nchk, errors);
        $display("hsync: period ok %0d bad %0d | width ok %0d bad %0d", hper_ok, hper_bad, hw_ok, hw_bad);
        $display("vsync: period ok %0d bad %0d | width ok %0d bad %0d", vper_ok, vper_bad, vw_ok, vw_bad);
        $display("frame_tick: period ok %0d bad %0d | count steps bad %0d", fper_ok, fper_bad, fcnt_bad);

        if (errors == 0 && hper_bad == 0 && hw_bad == 0 && vper_bad == 0 && vw_bad == 0 &&
            fper_bad == 0 && fcnt_bad == 0 &&
            hper_ok > 1000 && hw_ok > 1000 && vper_ok >= 1 && vw_ok >= 1 && fper_ok >= 1)
            $display("=== ALL TESTS PASSED ===");
        else
            $display("=== FAILED ===");
        $finish;
    end
endmodule