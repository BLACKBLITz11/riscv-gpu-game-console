`timescale 1ns/1ps
// Multi-tick test entirely through the host interface:
//   - program loaded via prog_* port (from entity_update.hex)
//   - entities spawned / respawned via spawn_* port (per-core local_mem)
//   - player / shot positions written via host_* port between ticks
//   - every tick, including the first, started with a `start` pulse
//     (START_HALTED=1: cores wait after reset)
// No hierarchical WRITES anywhere; hierarchy is only used to READ results.
module tb_multi_tick;
    localparam N = 32, TICKS = 40;
    reg clk = 0, rst, start = 0;
    reg         prog_we = 0;  reg [7:0]  prog_addr = 0;  reg [31:0] prog_data = 0;
    reg         host_we = 0;  reg [9:0]  host_addr = 0;  reg [31:0] host_wdata = 0;
    reg         spawn_we = 0; reg [4:0]  spawn_core = 0; reg [5:0]  spawn_addr = 0; reg [31:0] spawn_data = 0;
    wire all_done;
    integer errors = 0, checks = 0, hits = 0, wraps = 0, kept_dead = 0, stray_ok = 0, gate_ok = 0, respawns = 0;
    integer t, i, j, seed, cyc, k, plen_words;
    gpu_top #(.N_CORES(N), .START_HALTED(1)) uut (
        .clk(clk), .rst(rst), .start(start), .all_done(all_done),
        .prog_we(prog_we), .prog_addr(prog_addr), .prog_data(prog_data),
        .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
        .spawn_we(spawn_we), .spawn_core(spawn_core), .spawn_addr(spawn_addr), .spawn_data(spawn_data));
    always #5 clk = ~clk;

    // ---------- host-side tasks (drive on negedge, one write per cycle) ----------
    task host_write(input [9:0] a, input [31:0] d);
    begin
        @(negedge clk); host_we = 1; host_addr = a; host_wdata = d;
        @(negedge clk); host_we = 0;
    end
    endtask
    task prog_write(input [7:0] a, input [31:0] d);
    begin
        @(negedge clk); prog_we = 1; prog_addr = a; prog_data = d;
        @(negedge clk); prog_we = 0;
    end
    endtask
    task spawn_write(input [4:0] c, input [5:0] a, input [31:0] d);
    begin
        @(negedge clk); spawn_we = 1; spawn_core = c; spawn_addr = a; spawn_data = d;
        @(negedge clk); spawn_we = 0;
    end
    endtask

    reg [31:0] prog_img [0:255];

    // ---------- entity state: what the host last spawned, and the reference model ----------
    reg [31:0] in_px [0:N-1], in_py [0:N-1], in_vx [0:N-1], in_vy [0:N-1], in_al [0:N-1];
    reg [31:0] m_px [0:N-1], m_py [0:N-1], m_al [0:N-1];
    wire [31:0] o_px [0:N-1], o_py [0:N-1], o_vx [0:N-1], o_vy [0:N-1], o_al [0:N-1];
    genvar g;
    generate for (g = 0; g < N; g = g + 1) begin : hook   // read-only probes
        assign o_px[g] = uut.cores[g].core_inst.local_mem[0];
        assign o_py[g] = uut.cores[g].core_inst.local_mem[1];
        assign o_vx[g] = uut.cores[g].core_inst.local_mem[2];
        assign o_vy[g] = uut.cores[g].core_inst.local_mem[3];
        assign o_al[g] = uut.cores[g].core_inst.local_mem[4];
    end endgenerate

    // push in_*[c] into core c through the spawn port, and mirror it in the model
    task spawn_entity(input integer c);
    begin
        spawn_write(c, 0, in_px[c]);  spawn_write(c, 1, in_py[c]);
        spawn_write(c, 2, in_vx[c]);  spawn_write(c, 3, in_vy[c]);
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

    reg [31:0] sx, sy, npx, npy, ndx, ndy, rom0;
    reg [N-1:0] hb;
    integer tgt, tries, ox, oy;

    // one tick: start pulse (plen cycles), wait for the cores to leave and re-enter HALTED.
    // stray=1: mid-run, also try a start pulse, and junk host / ROM / spawn writes.
    task run_tick(input integer plen, input integer stray);
    begin
        @(negedge clk); start = 1;
        repeat (plen) @(negedge clk);
        start = 0;
        #1;
        if (all_done) begin errors = errors + 1; $display("FAIL tick %0d: cores did not leave HALTED", t); end
        if (uut.cores[5].core_inst.rf_inst.registers[1] !== 0 ||
            uut.cores[5].core_inst.rf_inst.registers[15] !== 5) begin
            errors = errors + 1; $display("FAIL tick %0d: regfile not re-initialised on start", t);
        end
        cyc = 0;
        while (!all_done && cyc < 20000) begin
            @(posedge clk); cyc = cyc + 1;
            if (stray && cyc == 40) begin
                hb = uut.halted; rom0 = uut.instr_rom[0];
                if (all_done || hb == 0) begin errors = errors + 1; $display("FAIL tick %0d: stray test not meaningful (halted=%h)", t, hb); end
                // (a) stray start
                @(negedge clk); start = 1; @(negedge clk); start = 0; #1;
                if ((uut.halted & hb) !== hb) begin
                    errors = errors + 1; $display("FAIL tick %0d: stray start restarted halted cores (%h -> %h)", t, hb, uut.halted);
                end else stray_ok = stray_ok + 1;
                // (b) junk host write (shot), junk ROM write, junk spawn write (vel_x of core 7,
                //     an address the program never writes) while cores are running
                @(negedge clk);
                host_we = 1; host_addr = 10'd2; host_wdata = 32'hDEAD;
                prog_we = 1; prog_addr = 8'd0;  prog_data = 32'h58000000;
                spawn_we = 1; spawn_core = 5'd7; spawn_addr = 6'd2; spawn_data = 32'hBEEF;
                @(negedge clk); host_we = 0; prog_we = 0; spawn_we = 0; #1;
                if (uut.mem.mem[2] !== sx || uut.mem.mem[3] !== sy || uut.instr_rom[0] !== rom0 ||
                    o_vx[7] !== in_vx[7]) begin
                    errors = errors + 1; $display("FAIL tick %0d: host/prog/spawn write accepted while cores running", t);
                end else gate_ok = gate_ok + 1;
            end
        end
        #1;
        if (!all_done) begin errors = errors + 1; $display("FAIL tick %0d: timeout", t); end
    end
    endtask

    initial begin
        seed = 32'hBADC0DE;
        $readmemh("entity_update.hex", prog_img);

        // ---- power-on: single reset, cores come up halted ----
        rst = 1; repeat (3) @(posedge clk);
        @(negedge clk); rst = 0; #1;
        if (!all_done) begin errors = errors + 1; $display("FAIL: cores not halted after reset (START_HALTED)"); end

        // ---- load program through the port ----
        plen_words = 0;
        while (prog_img[plen_words] !== 32'hxxxxxxxx && plen_words < 256) plen_words = plen_words + 1;
        for (i = 0; i < plen_words; i = i + 1) prog_write(i, prog_img[i]);
        @(negedge clk); #1;
        for (i = 0; i < plen_words; i = i + 1)
            if (uut.instr_rom[i] !== prog_img[i]) begin errors = errors + 1; $display("FAIL: ROM[%0d] readback mismatch", i); end
        $display("loaded %0d instructions through prog port", plen_words);

        // ---- initial global memory through the host port ----
        host_write(10'd0, 32'd50); host_write(10'd1, 32'd60);
        host_write(10'd2, 32'd0);  host_write(10'd3, 32'd0);
        sx = 0; sy = 0;

        // ---- spawn all entities through the spawn port (a few born dead), then read back ----
        for (i = 0; i < N; i = i + 1) begin
            random_entity(i, (i % 8 == 0) ? 1'b0 : 1'b1);
            spawn_entity(i);
        end
        @(negedge clk); #1;
        for (i = 0; i < N; i = i + 1)
            if (o_px[i] !== in_px[i] || o_py[i] !== in_py[i] || o_vx[i] !== in_vx[i] ||
                o_vy[i] !== in_vy[i] || o_al[i] !== in_al[i]) begin
                errors = errors + 1; $display("FAIL: spawn readback mismatch on core %0d", i);
            end
        $display("spawned %0d entities through spawn port", N);

        for (t = 0; t < TICKS; t = t + 1) begin
            // host respawns every dead entity at ticks 15 and 30 (between ticks)
            if (t == 15 || t == 30) begin
                for (i = 0; i < N; i = i + 1)
                    if (m_al[i] == 0) begin
                        random_entity(i, 1'b1); spawn_entity(i); respawns = respawns + 1;
                    end
            end
            if (t > 0) begin
                tgt = -1;
                for (tries = 0; tries < 8 && tgt < 0; tries = tries + 1) begin
                    k = $random(seed) & 31;
                    if (m_al[k]) tgt = k;
                end
                if (tgt >= 0 && ($random(seed) & 3) != 0) begin
                    ox = ($random(seed) % 11); oy = ($random(seed) % 11);
                    sx = (m_px[tgt] + in_vx[tgt] + ox) & 255;
                    sy = (m_py[tgt] + in_vy[tgt] + oy) & 255;
                end else begin sx = $random(seed) & 255; sy = $random(seed) & 255; end
                host_write(10'd2, sx); host_write(10'd3, sy);     // host moves the shot
            end
            run_tick((t == 3) ? 3 : 1, (t == 6));

            // ---- reference model for this tick ----
            for (i = 0; i < N; i = i + 1) begin
                if (m_al[i]) begin
                    npx = (m_px[i] + in_vx[i]) & 255;  npy = (m_py[i] + in_vy[i]) & 255;
                    if (m_px[i] + in_vx[i] != npx || m_py[i] + in_vy[i] != npy) wraps = wraps + 1;
                    m_px[i] = npx; m_py[i] = npy;
                    ndx = (npx > sx) ? npx - sx : sx - npx;
                    ndy = (npy > sy) ? npy - sy : sy - npy;
                    if (ndx <= 8 && ndy <= 8) begin m_al[i] = 0; hits = hits + 1; end
                end else if (t > 0) kept_dead = kept_dead + 1;
                checks = checks + 1;
                if (o_px[i] !== m_px[i] || o_py[i] !== m_py[i] || o_al[i] !== m_al[i] ||
                    o_vx[i] !== in_vx[i] || o_vy[i] !== in_vy[i]) begin
                    errors = errors + 1;
                    $display("FAIL tick %0d core %0d: got p=(%0d,%0d) a=%0d | exp p=(%0d,%0d) a=%0d",
                        t, i, o_px[i], o_py[i], o_al[i], m_px[i], m_py[i], m_al[i]);
                end
            end
            if (uut.mem.mem[0] !== 50 || uut.mem.mem[1] !== 60 || uut.mem.mem[2] !== sx || uut.mem.mem[3] !== sy) begin
                errors = errors + 1; $display("FAIL tick %0d: global memory not as host wrote it", t);
            end
        end
        $display("ticks=%0d checks=%0d hits=%0d wraps=%0d dead-entity-ticks-kept=%0d respawns=%0d",
                 TICKS, checks, hits, wraps, kept_dead, respawns);

        if (respawns > 0) $display("PASS: dead entities respawned through spawn port and ran again");
        else begin errors = errors + 1; $display("FAIL: no respawn happened (test not meaningful)"); end
        if (stray_ok == 1) $display("PASS: stray start mid-tick ignored (halted cores stayed halted)");
        else begin errors = errors + 1; $display("FAIL: stray-start check did not run"); end
        if (gate_ok == 1) $display("PASS: host/prog/spawn writes ignored while cores running");
        else begin errors = errors + 1; $display("FAIL: write-gating check did not run"); end

        // ---- full reset wipes memories, ROM survives (it's program storage) ----
        rst = 1; repeat (2) @(posedge clk); #1;
        if (uut.cores[3].core_inst.local_mem[0] !== 0 || uut.cores[3].core_inst.local_mem[4] !== 0 ||
            uut.mem.mem[2] !== 0) begin errors = errors + 1; $display("FAIL: rst did not clear memories"); end
        else $display("PASS: full rst clears local + global memory");
        if (uut.instr_rom[0] !== prog_img[0]) begin errors = errors + 1; $display("FAIL: rst clobbered the ROM"); end
        else $display("PASS: program ROM survives rst");

        if (errors == 0) $display("=== ALL TESTS PASSED ===");
        else $display("=== %0d FAILED ===", errors);
        $finish;
    end
endmodule