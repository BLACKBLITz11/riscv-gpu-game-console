// mock_gpu.v  -- TEST ONLY, replace with the real gpu_top for integration
module mock_gpu #(
    parameter TICK_CYCLES   = 30,
    parameter RENDER_CYCLES = 129
) (
    input             clk,
    input             rst,
    input             start,
    input             prog_we,
    input      [7:0]  prog_addr,
    input      [31:0] prog_data,
    input             host_we,
    input      [9:0]  host_addr,
    input      [31:0] host_wdata,
    input             spawn_we,
    input      [4:0]  spawn_core,
    input      [5:0]  spawn_addr,
    input      [31:0] spawn_data,
    input             render_start,
    output reg        all_done,
    output reg        render_busy,
    output reg        render_done
);
    reg [31:0] host_mem [0:1023];
    reg [31:0] spawn_mem [0:255];
    integer tick_cnt, render_cnt, i;
    integer start_count, spawn_count, prog_count, render_count;
    reg [4:0]  last_spawn_core;
    reg [5:0]  last_spawn_addr;
    reg [31:0] last_spawn_data;

    initial begin
        for (i = 0; i < 1024; i = i + 1) host_mem[i] = 32'b0;
        all_done = 1; render_busy = 0; render_done = 0;
        tick_cnt = 0; render_cnt = 0;
        start_count = 0; spawn_count = 0; prog_count = 0; render_count = 0;
    end

    always @(posedge clk) begin
        render_done <= 1'b0;
        if (rst) begin
            all_done <= 1'b1; render_busy <= 1'b0;
        end else begin
            if (host_we  && all_done)               host_mem[host_addr] <= host_wdata;
            if (prog_we  && all_done)               prog_count <= prog_count + 1;
            if (spawn_we && all_done && !render_busy) begin
                spawn_count <= spawn_count + 1;
                spawn_mem[{spawn_core, spawn_addr[2:0]}] <= spawn_data;
                last_spawn_core <= spawn_core;
                last_spawn_addr <= spawn_addr;
                last_spawn_data <= spawn_data;
            end

            if (start && all_done && !render_busy) begin
                all_done <= 1'b0; tick_cnt <= TICK_CYCLES; start_count <= start_count + 1;
            end else if (!all_done) begin
                if (tick_cnt <= 1) all_done <= 1'b1;
                tick_cnt <= tick_cnt - 1;
            end

            if (render_start && all_done && !render_busy && !start) begin
                render_busy <= 1'b1; render_cnt <= RENDER_CYCLES; render_count <= render_count + 1;
            end else if (render_busy) begin
                if (render_cnt <= 1) begin render_busy <= 1'b0; render_done <= 1'b1; end
                render_cnt <= render_cnt - 1;
            end
        end
    end
endmodule