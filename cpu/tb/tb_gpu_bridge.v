// tb_gpu_bridge.v
`timescale 1ns/1ps
module tb_gpu_bridge;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    wire        gpu_we, halted;
    wire [7:0]  gpu_offset;
    wire [31:0] gpu_wdata, gpu_rdata;

    wire        start, prog_we, host_we, spawn_we, render_start;
    wire [7:0]  prog_addr;
    wire [31:0] prog_data, host_wdata, spawn_data;
    wire [9:0]  host_addr;
    wire [4:0]  spawn_core;
    wire [5:0]  spawn_addr;
    wire        all_done, render_busy, render_done;

    cpu_system dut (.clk(clk), .rst(rst), .gpu_we(gpu_we), .gpu_re(),
                    .gpu_offset(gpu_offset), .gpu_wdata(gpu_wdata),
                    .gpu_rdata(gpu_rdata), .halted(halted));

    gpu_bridge #(.CORE_W(5)) bridge (
        .clk(clk), .rst(rst),
        .gpu_we(gpu_we), .gpu_offset(gpu_offset), .gpu_wdata(gpu_wdata), .gpu_rdata(gpu_rdata),
        .start(start), .prog_we(prog_we), .prog_addr(prog_addr), .prog_data(prog_data),
        .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
        .spawn_we(spawn_we), .spawn_core(spawn_core), .spawn_addr(spawn_addr), .spawn_data(spawn_data),
        .render_start(render_start), .all_done(all_done), .render_busy(render_busy));

    mock_gpu gpu (
        .clk(clk), .rst(rst), .start(start),
        .prog_we(prog_we), .prog_addr(prog_addr), .prog_data(prog_data),
        .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
        .spawn_we(spawn_we), .spawn_core(spawn_core), .spawn_addr(spawn_addr), .spawn_data(spawn_data),
        .render_start(render_start),
        .all_done(all_done), .render_busy(render_busy), .render_done(render_done));

    // ---- assembler helpers ----
    function [31:0] i_type(input [11:0] im, input [4:0] rs1, input [2:0] f3,
                           input [4:0] rd, input [6:0] op);
        i_type = {im, rs1, f3, rd, op};
    endfunction
    function [31:0] s_type(input [11:0] im, input [4:0] rs2, input [4:0] rs1, input [2:0] f3);
        s_type = {im[11:5], rs2, rs1, f3, im[4:0], 7'b0100011};
    endfunction
    function [31:0] b_type(input [12:0] im, input [4:0] rs2, input [4:0] rs1, input [2:0] f3);
        b_type = {im[12], im[10:5], rs2, rs1, f3, im[4:1], im[11], 7'b1100011};
    endfunction
    function [31:0] u_type(input [19:0] im, input [4:0] rd, input [6:0] op);
        u_type = {im, rd, op};
    endfunction
    task put(input integer idx, input [31:0] word);
        begin dut.u_imem.mem[idx] = word; end
    endtask

    integer errors = 0;
    integer cycles = 0;

    task chk(input [31:0] got, input [31:0] exp, input [127:0] name);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: got %h expected %h", name, got, exp);
            end
        end
    endtask

    initial begin
        #1;
        put(0,  u_type(20'h40000, 1, 7'h37));              // lui  x1,0x40000
        put(1,  i_type(100, 0, 3'b000, 2, 7'h13));         // addi x2,x0,100
        put(2,  s_type(12'h00, 2, 1, 3'b010));             // sw x2,PLAYER_X
        put(3,  i_type(50, 0, 3'b000, 3, 7'h13));          // addi x3,x0,50
        put(4,  s_type(12'h04, 3, 1, 3'b010));             // sw x3,PLAYER_Y
        put(5,  i_type(200, 0, 3'b000, 4, 7'h13));         // addi x4,x0,200
        put(6,  s_type(12'h08, 4, 1, 3'b010));             // sw x4,SHOT_X
        put(7,  i_type(77, 0, 3'b000, 5, 7'h13));          // addi x5,x0,77
        put(8,  s_type(12'h0C, 5, 1, 3'b010));             // sw x5,SHOT_Y
        put(9,  i_type(3, 0, 3'b000, 6, 7'h13));           // addi x6,x0,3
        put(10, s_type(12'h1C, 6, 1, 3'b010));             // sw x6,SPAWN_CORE
        put(11, i_type(2, 0, 3'b000, 6, 7'h13));           // addi x6,x0,2
        put(12, s_type(12'h20, 6, 1, 3'b010));             // sw x6,SPAWN_ADDR
        put(13, i_type(-1, 0, 3'b000, 7, 7'h13));          // addi x7,x0,-1
        put(14, s_type(12'h24, 7, 1, 3'b010));             // sw x7,SPAWN_DATA
        put(15, i_type(1, 0, 3'b000, 8, 7'h13));           // addi x8,x0,1
        put(16, s_type(12'h10, 8, 1, 3'b010));             // sw x8,START
        put(17, s_type(12'h08, 2, 1, 3'b010));             // sw x2,SHOT_X  (GPU busy: must be dropped)
        put(18, i_type(12'h14, 1, 3'b010, 9, 7'h03));      // lw x9,STATUS     (poll)
        put(19, i_type(1, 9, 3'b111, 9, 7'h13));           // andi x9,x9,1
        put(20, b_type(-8, 0, 9, 3'b000));                 // beq x9,x0,poll
        put(21, i_type(12'h14, 1, 3'b010, 10, 7'h03));     // lw x10,STATUS    (done + dropped)
        put(22, s_type(12'h14, 0, 1, 3'b010));             // sw x0,STATUS     (clear dropped)
        put(23, i_type(12'h14, 1, 3'b010, 11, 7'h03));     // lw x11,STATUS
        put(24, i_type(1, 0, 3'b000, 12, 7'h13));          // addi x12,x0,1
        put(25, s_type(12'h18, 12, 1, 3'b010));            // sw x12,RENDER
        put(26, i_type(12'h14, 1, 3'b010, 13, 7'h03));     // lw x13,STATUS    (poll)
        put(27, i_type(2, 13, 3'b111, 13, 7'h13));         // andi x13,x13,2
        put(28, b_type(-8, 0, 13, 3'b001));                // bne x13,x0,rpoll
        put(29, 32'h0);                                    // halt

        repeat (3) @(posedge clk);
        rst = 0;
        while (!halted && cycles < 5000) begin @(posedge clk); cycles = cycles + 1; end
        #1;
        if (!halted) begin errors = errors + 1; $display("FAIL: timeout"); end

        chk(gpu.host_mem[0], 100, "player_x");
        chk(gpu.host_mem[1], 50,  "player_y");
        chk(gpu.host_mem[2], 200, "shot_x (dropped write must not land)");
        chk(gpu.host_mem[3], 77,  "shot_y");
        chk(gpu.spawn_count, 1,   "spawn count");
        chk(gpu.last_spawn_core, 3, "spawn core");
        chk(gpu.last_spawn_addr, 2, "spawn addr");
        chk(gpu.last_spawn_data, 32'hFFFFFFFF, "spawn data");
        chk(gpu.start_count, 1,   "start count");
        chk(gpu.render_count, 1,  "render count");
        chk(dut.u_core.u_rf.regs[10], 5, "status: done + dropped");
        chk(dut.u_core.u_rf.regs[11], 1, "status after clear");
        chk(dut.u_core.u_rf.regs[13], 0, "render finished");

        if (errors == 0) $display("PASS: gpu bridge (%0d cycles)", cycles);
        else             $display("DONE: %0d errors", errors);
        $finish;
    end
endmodule