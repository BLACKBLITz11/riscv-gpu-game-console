`timescale 1ns/1ps
// Command-driven simulation of the whole console: RV32I CPU + bridge + gpu_top.
// Same file protocol as sim_server.v (cmd_NNNNNN.txt in, rsp_NNNNNN.txt + .done out).
//
// Commands (decimal integers):
//   PROG addr data     write one GPU instruction-ROM word (do this before GO)
//   GO                 release the CPU from reset (it starts running game.hex)
//   BUTTONS v          set the controller register (bit2 left, bit3 right, bit4 fire, bit5 respawn)
//   FRAME              run until the CPU has started one GPU tick and it has finished
//                      -> "TICK cycles" and "FRAMECYC cycles"
//   DUMP               -> 32 x "E core alive x y vx vy" and "HOSTS player_x player_y shot_x shot_y"
//   QUIT               end the simulation
module sim_cpu_server;
    localparam N = 32;
    reg clk = 0, clk_en = 0;
    reg gpu_rst = 1, cpu_rst = 1;
    reg [7:0] buttons = 0;

    // testbench-side loader for the GPU instruction ROM
    reg         ld_we = 0;
    reg  [7:0]  ld_addr = 0;
    reg  [31:0] ld_data = 0;

    wire        gpu_we, halted;
    wire [7:0]  gpu_offset;
    wire [31:0] gpu_wdata, gpu_rdata;
    wire        start, prog_we, host_we, spawn_we, render_start;
    wire [7:0]  prog_addr;
    wire [31:0] prog_data, host_wdata, spawn_data;
    wire [9:0]  host_addr;
    wire [4:0]  spawn_core;
    wire [5:0]  spawn_addr;
    wire        all_done, render_busy, render_done, fb_pixel;
    wire [7:0]  alive_count;

    wire        g_prog_we   = prog_we | ld_we;
    wire [7:0]  g_prog_addr = ld_we ? ld_addr : prog_addr;
    wire [31:0] g_prog_data = ld_we ? ld_data : prog_data;

    cpu_system #(.INIT_FILE("game.hex")) cpu (
        .clk(clk), .rst(cpu_rst), .buttons(buttons), .gpu_we(gpu_we), .gpu_re(),
        .gpu_offset(gpu_offset), .gpu_wdata(gpu_wdata), .gpu_rdata(gpu_rdata), .halted(halted));

    gpu_bridge #(.CORE_W(5)) bridge (
        .clk(clk), .rst(cpu_rst),
        .gpu_we(gpu_we), .gpu_offset(gpu_offset), .gpu_wdata(gpu_wdata), .gpu_rdata(gpu_rdata),
        .start(start), .prog_we(prog_we), .prog_addr(prog_addr), .prog_data(prog_data),
        .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
        .spawn_we(spawn_we), .spawn_core(spawn_core), .spawn_addr(spawn_addr), .spawn_data(spawn_data),
        .render_start(render_start), .all_done(all_done), .render_busy(render_busy), .alive_count(alive_count));

    gpu_top #(.N_CORES(N), .START_HALTED(1), .HAS_FB(1)) uut (
        .clk(clk), .rst(gpu_rst), .start(start), .all_done(all_done),
        .prog_we(g_prog_we), .prog_addr(g_prog_addr), .prog_data(g_prog_data),
        .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
        .spawn_we(spawn_we), .spawn_core(spawn_core), .spawn_addr(spawn_addr), .spawn_data(spawn_data),
        .render_start(render_start), .render_busy(render_busy), .render_done(render_done),
        .fb_x(8'd0), .fb_y(8'd0), .fb_pixel(fb_pixel), .alive_count(alive_count));

    // clock only runs while a command is executing
    always #5 if (clk_en) clk = ~clk;

    // what the CPU wrote to the GPU's global memory (player and shot)
    reg [31:0] host_shadow [0:9];
    integer start_count = 0;
       integer h;
       initial for (h = 0; h < 10; h = h + 1) host_shadow[h] = 0;
    always @(posedge clk) begin
        if (start && all_done && !render_busy) start_count <= start_count + 1;
        if (host_we && all_done && host_addr < 10) host_shadow[host_addr] <= host_wdata;
    end

    // read-only probes of entity state (same hooks as sim_server.v)
    wire [31:0] o_px [0:N-1], o_py [0:N-1], o_vx [0:N-1], o_vy [0:N-1], o_al [0:N-1];
    genvar g;
    generate for (g = 0; g < N; g = g + 1) begin : hook
        assign o_px[g] = uut.cores[g].core_inst.local_mem[0];
        assign o_py[g] = uut.cores[g].core_inst.local_mem[1];
        assign o_vx[g] = uut.cores[g].core_inst.local_mem[2];
        assign o_vy[g] = uut.cores[g].core_inst.local_mem[3];
        assign o_al[g] = uut.cores[g].core_inst.local_mem[4];
    end endgenerate

    integer seq, fd, rfd, r, a, b, cyc, cyc2, target, i;
    reg [8*16-1:0] word;
    reg [8*32-1:0] fname;

    task do_frame;
    begin
        target = start_count + 1; cyc = 0;
        while (start_count < target && cyc < 3000000 && !halted) begin
            @(posedge clk); cyc = cyc + 1;
        end
        if (start_count < target) $fdisplay(rfd, "ERR frame timeout (cpu halted=%0d)", halted);
        repeat (3) @(posedge clk);          // let all_done fall
        cyc2 = 3;
        while (!all_done && cyc2 < 200000) begin @(posedge clk); cyc2 = cyc2 + 1; end
        #1;
        if (!all_done) $fdisplay(rfd, "ERR tick timeout");
        $fdisplay(rfd, "TICK %0d", cyc2);
        $fdisplay(rfd, "FRAMECYC %0d", cyc);
    end
    endtask

    initial begin
        clk_en = 1;
        gpu_rst = 1; cpu_rst = 1; repeat (3) @(posedge clk);
        @(negedge clk); gpu_rst = 0; #1;          // GPU out of reset, CPU still held
        clk_en = 0;
        seq = 1;
        forever begin
            $sformat(fname, "cmd_%06d.txt", seq);
            fd = $fopen(fname, "r");
            if (fd == 0) begin
                #1000;
            end else begin
                $sformat(fname, "rsp_%06d.txt", seq);
                rfd = $fopen(fname, "w");
                clk_en = 1;
                while ($fscanf(fd, "%s", word) == 1) begin
                    if (word == "PROG") begin
                        r = $fscanf(fd, "%d %d", a, b);
                        @(negedge clk); ld_we = 1; ld_addr = a; ld_data = b;
                        @(negedge clk); ld_we = 0;
                    end
                    else if (word == "GO") begin
                        @(negedge clk); cpu_rst = 0;
                    end
                    else if (word == "BUTTONS") begin
                        r = $fscanf(fd, "%d", a);
                        buttons = a;
                    end
                    else if (word == "FRAME") do_frame;
                    else if (word == "DUMP") begin
                        for (i = 0; i < N; i = i + 1)
                            $fdisplay(rfd, "E %0d %0d %0d %0d %0d %0d", i, o_al[i] != 0,
                                      o_px[i], o_py[i], $signed(o_vx[i]), $signed(o_vy[i]));
                           $fdisplay(rfd, "HOSTS %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                                     host_shadow[0], host_shadow[1], host_shadow[2], host_shadow[3],
                                     host_shadow[4], host_shadow[5], host_shadow[6], host_shadow[7],
                                     host_shadow[8], host_shadow[9]);
                    end
                    else if (word == "QUIT") begin
                        $fdisplay(rfd, "OK");
                        $fclose(rfd); $fclose(fd);
                        $sformat(fname, "rsp_%06d.done", seq);
                        fd = $fopen(fname, "w"); $fclose(fd);
                        $finish;
                    end
                    else $fdisplay(rfd, "ERR unknown command %0s", word);
                end
                $fdisplay(rfd, "OK");
                clk_en = 0;
                $fclose(fd); $fclose(rfd);
                $sformat(fname, "rsp_%06d.done", seq);
                fd = $fopen(fname, "w"); $fclose(fd);
                seq = seq + 1;
            end
        end
    end
endmodule