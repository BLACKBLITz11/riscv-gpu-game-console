module mem_ctrl #(
    parameter N_CORES = 4
) (
    input                          clk,
    input                          rst,

    input  [N_CORES-1:0]           req,
    input  [N_CORES-1:0]           we,

    // flattened buses -- core i's slice is bits [i*W +: W].
    // Plain Verilog-2001 indexed part-select, NOT SystemVerilog array
    // ports (which Icarus 12.0 doesn't support), so this works the
    // same in simulation and synthesis.
    input  [N_CORES*10 - 1:0]      addr_flat,
    input  [N_CORES*32 - 1:0]      wdata_flat,
    output reg [N_CORES*32 - 1:0]  rdata_flat,

    output reg [N_CORES-1:0]       grant,

    // host write port (mem_ctrl's own 0-based address space, i.e. raw ISA
    // address minus 64). gpu_top only asserts host_we while all cores are
    // halted, so it never competes with a core's access.
    input                          host_we,
    input  [9:0]                   host_addr,
    input  [31:0]                  host_wdata
);

    localparam CW = (N_CORES <= 1) ? 1 : $clog2(N_CORES);

    reg [31:0] mem [0:1023];
    reg [CW-1:0] current;

    reg [9:0]  addr  [0:N_CORES-1];
    reg [31:0] wdata [0:N_CORES-1];

    integer i;
    always @(*) begin
        for (i = 0; i < N_CORES; i = i + 1) begin
            addr[i]  = addr_flat[i*10 +: 10];
            wdata[i] = wdata_flat[i*32 +: 32];
        end
    end

    // ONE write port, so the tools can build this as a RAM. The host and the
    // granted core never write in the same cycle (host_we is only asserted
    // while all cores are halted), so the host simply gets the port first.
    wire        w_en   = host_we | (req[current] & we[current]);
    wire [9:0]  w_addr = host_we ? host_addr  : addr[current];
    wire [31:0] w_data = host_we ? host_wdata : wdata[current];

`ifndef SYNTHESIS
    integer j;   // simulation only: clear the memory on reset (on the FPGA it powers up as zeros)
`endif

    always @(posedge clk) begin
        if (rst) begin
            current    <= 0;
            grant      <= 0;
            rdata_flat <= 0;
`ifndef SYNTHESIS
            for (j = 0; j < 1024; j = j + 1)
                mem[j] <= 32'h0;
`endif
        end
        else begin
            grant <= 0;

            if (req[current]) begin
                grant[current] <= 1;

                if (!we[current])
                    rdata_flat[current*32 +: 32] <= mem[addr[current]];

                current <= (current == N_CORES-1) ? 0 : current + 1;
            end
            else begin
                current <= (current == N_CORES-1) ? 0 : current + 1;
            end
        end

        if (!rst && w_en)
            mem[w_addr] <= w_data;
    end

endmodule