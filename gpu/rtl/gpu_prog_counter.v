module prog_counter (
    input         clk,      // clock
    input         rst,      // reset (goes back to 0)
    input         jump,     // 1 = jump to new address
    input  [7:0]  jump_addr,// address to jump to
    input         stall,    // 1 = freeze pc this cycle
    output reg [7:0] pc     // current instruction address
);

    always @(posedge clk) begin
        if (rst)
            pc <= 8'h0;        // reset to instruction 0
        else if (jump)
            pc <= jump_addr;   // jump to new address
        else if (stall)
            pc <= pc;          // freeze: hold current address
        else
            pc <= pc + 1;      // normal: go to next instruction
    end

endmodule