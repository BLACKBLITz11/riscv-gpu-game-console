// gpu_prog_loader.v -- copies the GPU program (hex file) into the GPU's instruction ROM
// through the prog_* port after reset. The CPU is held in reset until `done`.
module gpu_prog_loader #(
    parameter FILE = "entity_update.hex"
) (
    input             clk,
    input             rst,
    output reg        we,
    output reg [7:0]  addr,
    output reg [31:0] data,
    output reg        done
);
    reg [31:0] rom [0:255];
    integer k;
    initial begin
        for (k = 0; k < 256; k = k + 1) rom[k] = 32'h0;   // unused words stay 0
        $readmemh(FILE, rom);
    end

    reg [8:0] n;
    always @(posedge clk) begin
        if (rst) begin
            n <= 9'd0; we <= 1'b0; addr <= 8'd0; data <= 32'd0; done <= 1'b0;
        end else if (!done) begin
            if (n < 9'd256) begin
                we   <= 1'b1;
                addr <= n[7:0];
                data <= rom[n[7:0]];
                n    <= n + 9'd1;
            end else begin
                we   <= 1'b0;
                done <= 1'b1;
            end
        end
    end
endmodule