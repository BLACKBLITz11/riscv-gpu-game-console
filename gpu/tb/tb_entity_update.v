`timescale 1ns/1ps
// Verifies asm/entity_update.asm on gpu_top: 32 cores, one entity each.
// Reference model mirrors the program's documented semantics:
//   dead (alive==0): nothing changes
//   alive: pos = (pos+vel)&255 ; hit if |dx|<=8 && |dy|<=8 vs shot (global mem 2,3)
//          hit -> alive=0 ; pos written back either way
// Shot slots 1..3 (global words 4..9) are parked at 1000 so they never hit.
module tb_entity_update;
    localparam N = 32;
    reg clk = 0, rst;
    wire all_done;
    integer errors = 0, checks = 0, hits = 0, misses = 0, wraps = 0, deads = 0;
    integer r, i, seed;

    gpu_top #(.N_CORES(N)) uut (.clk(clk), .rst(rst), .start(1'b0), .all_done(all_done),
        .prog_we(1'b0), .prog_addr(8'b0), .prog_data(32'b0),
        .host_we(1'b0), .host_addr(10'b0), .host_wdata(32'b0));

    always #5 clk = ~clk;

    // per-core initial state / observed state
    reg [31:0] in_px [0:N-1], in_py [0:N-1], in_vx [0:N-1], in_vy [0:N-1], in_al [0:N-1];
    wire [31:0] o_px [0:N-1], o_py [0:N-1], o_vx [0:N-1], o_vy [0:N-1], o_al [0:N-1];
    event load_ev;
    genvar g;
    generate for (g = 0; g < N; g = g + 1) begin : hook
        assign o_px[g] = uut.cores[g].core_inst.local_mem[0];
        assign o_py[g] = uut.cores[g].core_inst.local_mem[1];
        assign o_vx[g] = uut.cores[g].core_inst.local_mem[2];
        assign o_vy[g] = uut.cores[g].core_inst.local_mem[3];
        assign o_al[g] = uut.cores[g].core_inst.local_mem[4];
        always @(load_ev) begin
            uut.cores[g].core_inst.local_mem[0] = in_px[g];
            uut.cores[g].core_inst.local_mem[1] = in_py[g];
            uut.cores[g].core_inst.local_mem[2] = in_vx[g];
            uut.cores[g].core_inst.local_mem[3] = in_vy[g];
            uut.cores[g].core_inst.local_mem[4] = in_al[g];
        end
    end endgenerate

    reg [31:0] sx, sy;
    reg [31:0] exp_px, exp_py, exp_al, ndx, ndy;
    integer cyc;

    // directed offsets (post-move position relative to shot) and velocities
    integer off_x [0:9]; integer off_y [0:9]; integer vel_x [0:9]; integer vel_y [0:9];
    initial begin
        off_x[0]=0;  off_y[0]=0;  vel_x[0]=1;   vel_y[0]=1;
        off_x[1]=8;  off_y[1]=8;  vel_x[1]=-1;  vel_y[1]=3;   // exact boundary -> hit
        off_x[2]=9;  off_y[2]=0;  vel_x[2]=3;   vel_y[2]=-4;  // dx just outside
        off_x[3]=0;  off_y[3]=9;  vel_x[3]=0;   vel_y[3]=0;   // dy just outside
        off_x[4]=8;  off_y[4]=9;  vel_x[4]=7;   vel_y[4]=7;
        off_x[5]=-8; off_y[5]=-8; vel_x[5]=200; vel_y[5]=-200;
        off_x[6]=-9; off_y[6]=-8; vel_x[6]=-1;  vel_y[6]=-1;
        off_x[7]=8;  off_y[7]=-9; vel_x[7]=2;   vel_y[7]=2;
        off_x[8]=5;  off_y[8]=-3; vel_x[8]=-7;  vel_y[8]=5;
        off_x[9]=-1; off_y[9]=0;  vel_x[9]=255; vel_y[9]=1;
    end

    task do_round(input [31:0] shx, input [31:0] shy);
    begin
        sx = shx; sy = shy;
        // build initial state
        for (i = 0; i < N; i = i + 1) begin
            if (i < 10) begin
                in_vx[i] = vel_x[i]; in_vy[i] = vel_y[i];
                in_px[i] = (shx + off_x[i] - vel_x[i]) & 255;
                in_py[i] = (shy + off_y[i] - vel_y[i]) & 255;
                in_al[i] = 1;
            end else if (i < 12) begin           // dead entities sitting on the shot
                in_vx[i] = 5; in_vy[i] = 5;
                in_px[i] = shx & 255; in_py[i] = shy & 255; in_al[i] = 0;
            end else if (i < 16) begin           // forced wrap cases (start near edges)
                in_vx[i] = (i==12) ? 5 : (i==13) ? -5 : 0;
                in_vy[i] = (i==12) ? 3 : (i==13) ? -3 : (i==14) ? 1 : -1;
                in_px[i] = (i==12) ? 254 : (i==13) ? 2 : (i==14) ? 0 : 255;
                in_py[i] = (i==12) ? 255 : (i==13) ? 1 : (i==14) ? 255 : 0;
                in_al[i] = 1;
            end else begin                       // random
                in_px[i] = $random(seed) & 255; in_py[i] = $random(seed) & 255;
                in_vx[i] = ($random(seed) % 16); in_vy[i] = ($random(seed) % 16);  // signed, +/-15
                in_al[i] = ($random(seed) & 3) != 0;
            end
        end
        // reset, then poke state on the negedge where rst drops (reset clears memories)
        rst = 1; repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;
        uut.mem.mem[0] = 32'd50; uut.mem.mem[1] = 32'd60;   // player (unused, must stay)
        uut.mem.mem[2] = shx;    uut.mem.mem[3] = shy;       // shot
        uut.mem.mem[4] = 1000; uut.mem.mem[5] = 1000; uut.mem.mem[6] = 1000;
        uut.mem.mem[7] = 1000; uut.mem.mem[8] = 1000; uut.mem.mem[9] = 1000;   // slots 1..3 parked
        -> load_ev;

        cyc = 0;
        while (!all_done && cyc < 20000) begin @(posedge clk); cyc = cyc + 1; end
        #1;
        if (!all_done) begin $display("FAIL: round shot=(%0d,%0d) timeout", shx, shy); errors = errors + 1; end
        else $display("round shot=(%0d,%0d): all_done after %0d cycles", shx, shy, cyc);

        for (i = 0; i < N; i = i + 1) begin
            if (in_al[i] == 0) begin
                exp_px = in_px[i]; exp_py = in_py[i]; exp_al = 0; deads = deads + 1;
            end else begin
                exp_px = (in_px[i] + in_vx[i]) & 255;
                exp_py = (in_py[i] + in_vy[i]) & 255;
                if (in_px[i] + in_vx[i] != exp_px || in_py[i] + in_vy[i] != exp_py) wraps = wraps + 1;
                ndx = (exp_px > sx) ? exp_px - sx : sx - exp_px;
                ndy = (exp_py > sy) ? exp_py - sy : sy - exp_py;
                if (ndx <= 8 && ndy <= 8) begin exp_al = 0; hits = hits + 1; end
                else begin exp_al = 1; misses = misses + 1; end
            end
            checks = checks + 1;
            if (o_px[i] !== exp_px || o_py[i] !== exp_py || o_al[i] !== exp_al ||
                o_vx[i] !== in_vx[i] || o_vy[i] !== in_vy[i]) begin
                errors = errors + 1;
                $display("FAIL core %0d: in p=(%0d,%0d) v=(%0d,%0d) a=%0d | got p=(%0d,%0d) a=%0d v=(%0d,%0d) | exp p=(%0d,%0d) a=%0d",
                    i, in_px[i], in_py[i], $signed(in_vx[i]), $signed(in_vy[i]), in_al[i],
                    o_px[i], o_py[i], o_al[i], $signed(o_vx[i]), $signed(o_vy[i]), exp_px, exp_py, exp_al);
            end
        end
        // global memory must be read-only for this program
        if (uut.mem.mem[0] !== 50 || uut.mem.mem[1] !== 60 || uut.mem.mem[2] !== shx || uut.mem.mem[3] !== shy ||
            uut.mem.mem[4] !== 1000 || uut.mem.mem[9] !== 1000) begin
            errors = errors + 1; $display("FAIL: global memory was modified");
        end
    end
    endtask

    initial begin
        seed = 32'hC0FFEE;
        `include "entity_rom_fill.vh"
        do_round(100, 100);
        do_round(0, 0);
        do_round(255, 255);
        do_round(128, 3);
        $display("checks=%0d hits=%0d misses=%0d wraps=%0d dead=%0d", checks, hits, misses, wraps, deads);
        if (errors == 0) $display("=== ALL TESTS PASSED ===");
        else $display("=== %0d FAILED ===", errors);
        $finish;
    end
endmodule