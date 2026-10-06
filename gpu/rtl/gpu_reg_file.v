module reg_file #(
    parameter CORE_ID = 0    // this core's unique ID, hardwired at build time
) (
    input         clk,
    input         rst,
    input         we,
    input  [3:0]  r_addr1,
    input  [3:0]  r_addr2,
    input  [3:0]  w_addr,
    input  [31:0] w_data,
    output [31:0] r_data1,
    output [31:0] r_data2
);

    reg [31:0] registers [0:15];
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 15; i = i + 1)
                registers[i] <= 32'h0;
            registers[15] <= CORE_ID;   // R15 is read-only, holds this core's ID
        end
        else if (we && w_addr != 4'd15) begin
            registers[w_addr] <= w_data;
        end
    end

    assign r_data1 = registers[r_addr1];
    assign r_data2 = registers[r_addr2];

endmodule