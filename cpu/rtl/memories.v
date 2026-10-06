// memories.v
// Instruction memory: 1024 words (4 KB), synchronous read.
module imem #(
    parameter INIT_FILE = ""
) (
    input             clk,
    input      [31:0] addr,
    output reg [31:0] data
);
    reg [31:0] mem [0:1023];
    integer i;
    initial begin
        for (i = 0; i < 1024; i = i + 1) mem[i] = 32'b0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end
    always @(posedge clk) data <= mem[addr[11:2]];
endmodule

// Data memory: 1024 words (4 KB), synchronous read, word writes.
module dmem (
    input             clk,
    input             we,
    input      [31:0] addr,
    input      [31:0] wdata,
    output reg [31:0] rdata
);
    reg [31:0] mem [0:1023];
    integer i;
    initial for (i = 0; i < 1024; i = i + 1) mem[i] = 32'b0;
    always @(posedge clk) begin
        if (we) mem[addr[11:2]] <= wdata;
        rdata <= mem[addr[11:2]];
    end
endmodule