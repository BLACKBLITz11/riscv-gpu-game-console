`timescale 1ns/1ps
module tb_mem_ctrl_param #(parameter N_CORES = 4);
    reg clk = 0;
    reg rst;
    reg  [N_CORES-1:0] req, we;
    reg  [N_CORES*10-1:0] addr_flat;
    reg  [N_CORES*32-1:0] wdata_flat;
    wire [N_CORES*32-1:0] rdata_flat;
    wire [N_CORES-1:0] grant;

    integer errors = 0;

    mem_ctrl #(.N_CORES(N_CORES)) uut (
        .clk(clk), .rst(rst), .req(req), .we(we),
        .addr_flat(addr_flat), .wdata_flat(wdata_flat),
        .rdata_flat(rdata_flat), .grant(grant),
        .host_we(1'b0), .host_addr(10'b0), .host_wdata(32'b0)
    );

    always #5 clk = ~clk;

    integer k;
    reg [N_CORES-1:0] grants_seen;

    initial begin
        rst = 1; req = 0; we = 0; addr_flat = 0; wdata_flat = 0;
        @(negedge clk); rst = 0;

        req = {N_CORES{1'b1}};
        we  = {N_CORES{1'b1}};
        for (k = 0; k < N_CORES; k = k + 1) begin
            addr_flat[k*10 +: 10]   = k + 50;
            wdata_flat[k*32 +: 32] = (k+1) * 10;
        end

        grants_seen = 0;
        for (k = 0; k < N_CORES; k = k + 1) begin
            @(posedge clk); #1;
            grants_seen = grants_seen | grant;
        end
        req = 0; we = 0;

        if (grants_seen !== {N_CORES{1'b1}}) begin
            $display("FAIL [N_CORES=%0d]: not all cores granted -- saw %b", N_CORES, grants_seen);
            errors = errors + 1;
        end else begin
            $display("PASS [N_CORES=%0d]: all %0d cores granted across one rotation", N_CORES, N_CORES);
        end

        for (k = 0; k < N_CORES; k = k + 1) begin
            if (uut.mem[k+50] !== (k+1)*10) begin
                $display("FAIL [N_CORES=%0d]: core%0d wrote wrong value -- mem[%0d]=%0d, expected %0d",
                    N_CORES, k, k+50, uut.mem[k+50], (k+1)*10);
                errors = errors + 1;
            end
        end
        if (errors == 0)
            $display("PASS [N_CORES=%0d]: every core's write landed at the correct independent address", N_CORES);

        if (errors == 0)
            $display("=== N_CORES=%0d: ALL TESTS PASSED ===\n", N_CORES);
        else
            $display("=== N_CORES=%0d: %0d TEST(S) FAILED ===\n", N_CORES, errors);

        $finish;
    end
endmodule