`timescale 1ns/1ps
// Command-driven simulation of gpu_top, for the Python host (gpu_host.py).
//
// Protocol (file based, so it behaves the same on Windows / Linux / macOS):
//   host writes  cmd_NNNNNN.txt   (complete, then renamed into place)
//   this module executes every command in it, writing results to rsp_NNNNNN.txt,
//   then creates rsp_NNNNNN.done as the "response is complete" marker.
//   NNNNNN counts up from 000001.
//
// Commands (whitespace separated; integers are decimal, negatives allowed):
//   RESET                     reset the GPU (clears memories; ROM is kept)
//   PROG  addr data           write one instruction-ROM word
//   HOST  addr data           write one global-memory word
//   SPAWN core addr data      write one word of a core's local memory
//   START                     pulse start, wait for all_done      -> "TICK cycles"
//   RENDER                    pulse render_start, wait for done   -> "RENDER cycles"
//   PIXEL x y                 read one framebuffer pixel          -> "PIXEL x y v"
//   DUMP                      read all entity state               -> 32 x "E core alive x y vx vy"
//   QUIT                      end the simulation
module sim_server;
    localparam N = 32;
    reg clk = 0, clk_en = 0, rst = 1, start = 0, render_start = 0;
    reg         prog_we = 0;  reg [7:0]  prog_addr = 0;  reg [31:0] prog_data = 0;
    reg         host_we = 0;  reg [9:0]  host_addr = 0;  reg [31:0] host_wdata = 0;
    reg         spawn_we = 0; reg [4:0]  spawn_core = 0; reg [5:0]  spawn_addr = 0; reg [31:0] spawn_data = 0;
    reg  [7:0]  fb_x = 0, fb_y = 0;
    wire all_done, render_busy, render_done, fb_pixel;

    gpu_top #(.N_CORES(N), .START_HALTED(1), .HAS_FB(1)) uut (
        .clk(clk), .rst(rst), .start(start), .all_done(all_done),
        .prog_we(prog_we), .prog_addr(prog_addr), .prog_data(prog_data),
        .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
        .spawn_we(spawn_we), .spawn_core(spawn_core), .spawn_addr(spawn_addr), .spawn_data(spawn_data),
        .render_start(render_start), .render_busy(render_busy), .render_done(render_done),
        .fb_x(fb_x), .fb_y(fb_y), .fb_pixel(fb_pixel));

    // clock only runs while a command is executing (idle polling costs almost nothing)
    always #5 if (clk_en) clk = ~clk;

    // read-only probes of entity state
    wire [31:0] o_px [0:N-1], o_py [0:N-1], o_vx [0:N-1], o_vy [0:N-1], o_al [0:N-1];
    genvar g;
    generate for (g = 0; g < N; g = g + 1) begin : hook
        assign o_px[g] = uut.cores[g].core_inst.local_mem[0];
        assign o_py[g] = uut.cores[g].core_inst.local_mem[1];
        assign o_vx[g] = uut.cores[g].core_inst.local_mem[2];
        assign o_vy[g] = uut.cores[g].core_inst.local_mem[3];
        assign o_al[g] = uut.cores[g].core_inst.local_mem[4];
    end endgenerate

    integer seq, fd, rfd, r, a, b, c, cyc, i;
    reg [8*16-1:0] word;
    reg [8*32-1:0] fname;

    task do_reset;
    begin
        rst = 1; repeat (3) @(posedge clk);
        @(negedge clk); rst = 0; #1;
    end
    endtask
    task do_start;
    begin
        @(negedge clk); start = 1; @(negedge clk); start = 0; #1;
        cyc = 0;
        while (!all_done && cyc < 200000) begin @(posedge clk); cyc = cyc + 1; end
        #1;
        if (!all_done) $fdisplay(rfd, "ERR start timeout");
        $fdisplay(rfd, "TICK %0d", cyc);
    end
    endtask
    task do_render;
    begin
        @(negedge clk); render_start = 1; @(negedge clk); render_start = 0; #1;
        cyc = 0;
        while (render_busy && cyc < 20000) begin @(posedge clk); cyc = cyc + 1; end
        #1;
        $fdisplay(rfd, "RENDER %0d", cyc);
    end
    endtask

    initial begin
        clk_en = 1;
        do_reset;
        clk_en = 0;
        seq = 1;
        forever begin
            $sformat(fname, "cmd_%06d.txt", seq);
            fd = $fopen(fname, "r");
            if (fd == 0) begin
                #1000;                                   // nothing yet: poll again
            end else begin
                $sformat(fname, "rsp_%06d.txt", seq);
                rfd = $fopen(fname, "w");
                clk_en = 1;
                while ($fscanf(fd, "%s", word) == 1) begin
                    if (word == "RESET") do_reset;
                    else if (word == "PROG") begin
                        r = $fscanf(fd, "%d %d", a, b);
                        @(negedge clk); prog_we = 1; prog_addr = a; prog_data = b;
                        @(negedge clk); prog_we = 0;
                    end
                    else if (word == "HOST") begin
                        r = $fscanf(fd, "%d %d", a, b);
                        @(negedge clk); host_we = 1; host_addr = a; host_wdata = b;
                        @(negedge clk); host_we = 0;
                    end
                    else if (word == "SPAWN") begin
                        r = $fscanf(fd, "%d %d %d", a, b, c);
                        @(negedge clk); spawn_we = 1; spawn_core = a; spawn_addr = b; spawn_data = c;
                        @(negedge clk); spawn_we = 0;
                    end
                    else if (word == "START") do_start;
                    else if (word == "RENDER") do_render;
                    else if (word == "PIXEL") begin
                        r = $fscanf(fd, "%d %d", a, b);
                        fb_x = a; fb_y = b; #1;
                        $fdisplay(rfd, "PIXEL %0d %0d %0d", a, b, fb_pixel);
                    end
                    else if (word == "DUMP") begin
                        for (i = 0; i < N; i = i + 1)
                            $fdisplay(rfd, "E %0d %0d %0d %0d %0d %0d", i, o_al[i] != 0,
                                      o_px[i], o_py[i], $signed(o_vx[i]), $signed(o_vy[i]));
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
                $sformat(fname, "rsp_%06d.done", seq);   // marker last: response is complete
                fd = $fopen(fname, "w"); $fclose(fd);
                seq = seq + 1;
            end
        end
    end
endmodule