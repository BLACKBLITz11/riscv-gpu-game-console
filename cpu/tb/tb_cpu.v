// tb_cpu.v
`timescale 1ns/1ps
module tb_cpu;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    wire        gpu_we, gpu_re, halted;
    wire [7:0]  gpu_offset;
    wire [31:0] gpu_wdata;
    reg  [31:0] gpu_rdata = 32'd3;   // pretend STATUS = done + busy bits

    cpu_system dut (.clk(clk), .rst(rst), .gpu_we(gpu_we), .gpu_re(gpu_re),
                    .gpu_offset(gpu_offset), .gpu_wdata(gpu_wdata),
                    .gpu_rdata(gpu_rdata), .halted(halted));

    // ---- tiny assembler helpers ----
    function [31:0] r_type(input [6:0] f7, input [4:0] rs2, input [4:0] rs1,
                           input [2:0] f3, input [4:0] rd);
        r_type = {f7, rs2, rs1, f3, rd, 7'b0110011};
    endfunction
    function [31:0] i_type(input [11:0] im, input [4:0] rs1, input [2:0] f3,
                           input [4:0] rd, input [6:0] op);
        i_type = {im, rs1, f3, rd, op};
    endfunction
    function [31:0] s_type(input [11:0] im, input [4:0] rs2, input [4:0] rs1,
                           input [2:0] f3);
        s_type = {im[11:5], rs2, rs1, f3, im[4:0], 7'b0100011};
    endfunction
    function [31:0] b_type(input [12:0] im, input [4:0] rs2, input [4:0] rs1,
                           input [2:0] f3);
        b_type = {im[12], im[10:5], rs2, rs1, f3, im[4:1], im[11], 7'b1100011};
    endfunction
    function [31:0] u_type(input [19:0] im, input [4:0] rd, input [6:0] op);
        u_type = {im, rd, op};
    endfunction
    function [31:0] j_type(input [20:0] im, input [4:0] rd);
        j_type = {im[20], im[10:1], im[11], im[19:12], rd, 7'b1101111};
    endfunction

    task put(input integer idx, input [31:0] word);
        begin dut.u_imem.mem[idx] = word; end
    endtask

    integer errors = 0;
    integer cycles = 0;

    task chk_reg(input integer n, input [31:0] exp);
        begin
            if (dut.u_core.u_rf.regs[n] !== exp) begin
                errors = errors + 1;
                $display("FAIL x%0d = %h, expected %h", n, dut.u_core.u_rf.regs[n], exp);
            end
        end
    endtask

    task chk_mem(input integer w, input [31:0] exp);
        begin
            if (dut.u_dmem.mem[w] !== exp) begin
                errors = errors + 1;
                $display("FAIL dmem[%0d] = %h, expected %h", w, dut.u_dmem.mem[w], exp);
            end
        end
    endtask

    // watch GPU bus writes
    integer g_cnt = 0;
    reg [7:0]  g_off;
    reg [31:0] g_data;
    always @(posedge clk) if (gpu_we) begin
        g_cnt = g_cnt + 1; g_off = gpu_offset; g_data = gpu_wdata;
    end

    initial begin
        #1;
        put(0,  i_type(5, 0, 3'b000, 1, 7'h13));          // addi x1,x0,5
        put(1,  i_type(7, 0, 3'b000, 2, 7'h13));          // addi x2,x0,7
        put(2,  r_type(7'h00, 2, 1, 3'b000, 3));          // add  x3,x1,x2
        put(3,  r_type(7'h20, 2, 1, 3'b000, 4));          // sub  x4,x1,x2
        put(4,  s_type(0, 3, 0, 3'b010));                 // sw   x3,0(x0)
        put(5,  i_type(0, 0, 3'b010, 5, 7'h03));          // lw   x5,0(x0)
        put(6,  u_type(20'h12345, 6, 7'h37));             // lui  x6,0x12345
        put(7,  i_type(3, 1, 3'b001, 7, 7'h13));          // slli x7,x1,3
        put(8,  i_type(12'h401, 4, 3'b101, 8, 7'h13));    // srai x8,x4,1
        put(9,  i_type(0, 0, 3'b000, 9, 7'h13));          // addi x9,x0,0
        put(10, i_type(10, 0, 3'b000, 10, 7'h13));        // addi x10,x0,10
        put(11, r_type(7'h00, 10, 9, 3'b000, 9));         // add  x9,x9,x10   (loop)
        put(12, i_type(-1, 10, 3'b000, 10, 7'h13));       // addi x10,x10,-1
        put(13, b_type(-8, 0, 10, 3'b001));               // bne  x10,x0,loop
        put(14, j_type(8, 11));                           // jal  x11,+8
        put(15, i_type(99, 0, 3'b000, 12, 7'h13));        // (skipped)
        put(16, u_type(0, 13, 7'h17));                    // auipc x13,0
        put(17, i_type(80, 0, 3'b000, 14, 7'h13));        // addi x14,x0,80
        put(18, i_type(0, 14, 3'b000, 15, 7'h67));        // jalr x15,0(x14)
        put(19, i_type(77, 0, 3'b000, 12, 7'h13));        // (skipped)
        put(20, s_type(4, 9, 0, 3'b010));                 // sw   x9,4(x0)
        put(21, u_type(20'h40000, 16, 7'h37));            // lui  x16,0x40000
        put(22, i_type(42, 0, 3'b000, 17, 7'h13));        // addi x17,x0,42
        put(23, s_type(8, 17, 16, 3'b010));               // sw   x17,8(x16)  GPU_SHOT_X
        put(24, i_type(20, 16, 3'b010, 18, 7'h03));       // lw   x18,20(x16) GPU_STATUS
        put(25, 32'h0);                                   // illegal -> halt

        repeat (3) @(posedge clk);
        rst = 0;

        while (!halted && cycles < 5000) begin
            @(posedge clk); cycles = cycles + 1;
        end
        #1;
        if (!halted) begin errors = errors + 1; $display("FAIL: timeout"); end

        chk_reg(1, 5);          chk_reg(2, 7);
        chk_reg(3, 12);         chk_reg(4, 32'hFFFFFFFE);
        chk_reg(5, 12);         chk_reg(6, 32'h12345000);
        chk_reg(7, 40);         chk_reg(8, 32'hFFFFFFFF);
        chk_reg(9, 55);         chk_reg(10, 0);
        chk_reg(11, 60);        chk_reg(12, 0);
        chk_reg(13, 64);        chk_reg(14, 80);
        chk_reg(15, 76);        chk_reg(16, 32'h40000000);
        chk_reg(17, 42);        chk_reg(18, 3);
        chk_mem(0, 12);         chk_mem(1, 55);

        if (g_cnt !== 1 || g_off !== 8'h08 || g_data !== 32'd42) begin
            errors = errors + 1;
            $display("FAIL gpu write: cnt=%0d off=%h data=%h", g_cnt, g_off, g_data);
        end

        if (errors == 0) $display("PASS: cpu program (%0d cycles)", cycles);
        else             $display("DONE: %0d errors", errors);
        $finish;
    end
endmodule