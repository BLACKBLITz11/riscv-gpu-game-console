// prog_counter.v
module cpu_prog_counter #(
    parameter RESET_ADDR = 32'h0000_0000
) (
    input             clk,
    input             rst,
    input             stall,      // 1 = hold PC
    input             load,       // 1 = jump to target (branch taken, JAL, JALR)
    input      [31:0] target,
    output reg [31:0] pc,
    output     [31:0] pc_plus4    // return address for JAL/JALR
);
    assign pc_plus4 = pc + 32'd4;

    always @(posedge clk) begin
        if (rst)
            pc <= RESET_ADDR;
        else if (!stall) begin
            if (load)
                pc <= {target[31:2], 2'b00};
            else
                pc <= pc_plus4;
        end
    end
endmodule