`timescale 1ns/1ps
// Whole-console test: CPU runs game.hex, GPU draws, VGA scans out.
// 1. waits for 12 GPU ticks (proves loader + CPU + bridge + GPU all work together)
// 2. freezes the CPU, waits for the GPU to go idle (framebuffer now static)
// 3. checks EVERY VGA output pixel for ~1.06 frames against the framebuffer contents
// Run from the repo root (hex paths below are relative to it).
module tb_console_top;
    reg clk = 0, rst = 1;
    always #12.5 clk = ~clk;                       // 40 MHz

    wire hs, vs;
    wire [3:0] r, g, b;
    console_top #(.N_CORES(32), .CPU_HEX("fpga/game.hex"), .GPU_HEX("gpu/sw/entity_update.hex"), .SIM_FAST(1)) dut (
        .clk(clk), .rst(rst),
        .btnl(1'b0), .btnr(1'b1), .btnc(1'b1), .btnu(1'b0), .btnd(1'b0), .sw(2'b01),
        .vga_hs(hs), .vga_vs(vs), .vga_r(r), .vga_g(g), .vga_b(b));

    integer ticks = 0, cyc = 0, errors = 0, lit = 0, nchk = 0, pop = 0, k;
    always @(posedge clk) if (dut.start && dut.all_done && !dut.render_busy) ticks <= ticks + 1;

    // ---- scoreboard: expected pixel from the framebuffer array, 2 clocks behind the beam ----
    reg scoring = 0;
    reg e1 = 0, e2 = 0, s1 = 0, s2 = 0;
    wire in_img = (dut.vga.hc >= 144) && (dut.vga.hc < 656) && (dut.vga.vc >= 44) && (dut.vga.vc < 556);
    always @(posedge clk) begin
        e1 <= in_img & dut.gpu.fbuf.fb.fb[{dut.vga.fb_y, dut.vga.fb_x}];
        e2 <= e1;
        s1 <= scoring; s2 <= s1;
    end
    always @(negedge clk) if (s2) begin
        nchk = nchk + 1;
        if (e2) lit = lit + 1;
        if (r !== {4{e2}} || g !== {4{e2}} || b !== {4{e2}}) begin
            errors = errors + 1;
            if (errors <= 5)
                $display("MISMATCH at beam (%0d,%0d): rgb=%h%h%h expected pixel=%b",
                         dut.vga.hc, dut.vga.vc, r, g, b, e2);
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 0;

        cyc = 0;
        while (ticks < 12 && cyc < 1000000) begin @(posedge clk); cyc = cyc + 1; end
        if (ticks < 12) begin
            errors = errors + 1;
            $display("FAIL: only %0d GPU ticks after %0d clocks (loader done=%b, cpu halted=%b)",
                     ticks, cyc, dut.ld_done, dut.cpu_halted);
        end else
            $display("CPU ran %0d GPU ticks in %0d clocks", ticks, cyc);

        force dut.cpu_rst = 1'b1;                  // freeze the game
        repeat (4) @(posedge clk);
        cyc = 0;
        while (!(dut.all_done && !dut.render_busy) && cyc < 100000) begin @(posedge clk); cyc = cyc + 1; end
        repeat (50) @(posedge clk);

        pop = 0;
        for (k = 0; k < 65536; k = k + 1) if (dut.gpu.fbuf.fb.fb[k] === 1'b1) pop = pop + 1;
        $display("framebuffer holds %0d lit pixels", pop);
        if (pop == 0) begin errors = errors + 1; $display("FAIL: framebuffer is empty"); end

        scoring = 1;
        repeat (700000) @(posedge clk);
        scoring = 0;
        repeat (4) @(posedge clk);

        $display("compared %0d clocks of VGA output, %0d lit pixels seen, %0d mismatches", nchk, lit, errors);
        if (lit == 0) begin errors = errors + 1; $display("FAIL: no lit pixel reached the screen"); end
        if (errors == 0) $display("=== ALL TESTS PASSED ===");
        else             $display("=== FAILED ===");
        $finish;
    end
endmodule