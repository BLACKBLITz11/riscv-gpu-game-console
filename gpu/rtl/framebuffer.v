// 256x256 1-bit framebuffer, redrawn from the cores' entity state.
//
// render_start (accepted only when idle AND all cores are halted):
//   ERASE phase: clear the pixel each entity was drawn at last frame
//   DRAW  phase: for every core read alive / pos_x / pos_y through the
//                cores' local_mem read port and set that pixel if alive
// Erase-then-draw (not clear-all) keeps a frame at ~4*N cycles, not 65536.
//
// alive_count: number of alive entities seen by the last COMPLETED frame.
//
// Pixel readout: rd_x / rd_y -> rd_pixel (registered: valid one clock later).
module framebuffer #(
    parameter N_CORES    = 32,
    parameter CORE_W     = (N_CORES <= 1) ? 1 : $clog2(N_CORES),
    parameter ADDR_X     = 0,    // local_mem word holding pos_x
    parameter ADDR_Y     = 1,    // local_mem word holding pos_y
    parameter ADDR_ALIVE = 4     // local_mem word holding the alive flag
) (
    input                 clk,
    input                 rst,
    input                 all_done,      // cores halted -> local_mem is stable
    input                 render_start,  // 1-cycle pulse
    output                busy,          // high while rendering
    output reg            done,          // 1-cycle pulse when a frame is finished
    output reg [7:0]      alive_count,   // alive entities in the last finished frame

    // read port into the cores' local_mem (via gpu_top)
    output [CORE_W-1:0]   peek_core,
    output [5:0]          peek_addr,
    input  [31:0]         peek_data,

    // pixel readout
    input  [7:0]          rd_x,
    input  [7:0]          rd_y,
    output                rd_pixel
);
    reg fb [0:65535];
    reg [15:0] prev_xy    [0:N_CORES-1];
    reg        prev_valid [0:N_CORES-1];

    localparam IDLE = 2'd0, ERASE = 2'd1, DRAW = 2'd2;
    reg [1:0]        st;
    reg [CORE_W-1:0] c;
    reg [1:0]        sub;
    reg              alive_r;
    reg [7:0]        px_r;
    reg [7:0]        acc;      // running alive count during a frame

    assign busy      = (st != IDLE);
    assign peek_core = c;
    assign peek_addr = (sub == 2'd0) ? ADDR_ALIVE[5:0] :
                       (sub == 2'd1) ? ADDR_X[5:0]     : ADDR_Y[5:0];

    // registered (synchronous) read: lets the tools use block RAM on the FPGA.
    // rd_pixel is valid one clock after rd_x / rd_y change.
    reg rd_pixel_r;
    always @(posedge clk) rd_pixel_r <= fb[{rd_y, rd_x}];
    assign rd_pixel  = rd_pixel_r;

    // ONE write port into the pixel memory, so the tools can build it as a RAM:
    // ERASE clears last frame's pixel, DRAW sets this frame's pixel.
    reg        fb_we;
    reg [15:0] fb_waddr;
    reg        fb_wdata;
    always @(*) begin
        fb_we = 1'b0; fb_waddr = 16'd0; fb_wdata = 1'b0;
        if (!rst && st == ERASE && prev_valid[c]) begin
            fb_we = 1'b1; fb_waddr = prev_xy[c]; fb_wdata = 1'b0;
        end
        else if (!rst && st == DRAW && sub == 2'd2 && alive_r) begin
            fb_we = 1'b1; fb_waddr = {peek_data[7:0], px_r}; fb_wdata = 1'b1;
        end
    end

    integer j;
    always @(posedge clk) begin
        done <= 0;
        if (rst) begin
            st <= IDLE; c <= 0; sub <= 0; alive_r <= 0; px_r <= 0;
            acc <= 0; alive_count <= 0;
`ifndef SYNTHESIS
            for (j = 0; j < 65536; j = j + 1) fb[j] <= 1'b0;   // simulation only
`endif
            for (j = 0; j < N_CORES; j = j + 1) prev_valid[j] <= 1'b0;
        end
        else begin
            case (st)
                IDLE: if (render_start && all_done) begin
                    st <= ERASE; c <= 0; sub <= 0; acc <= 0;
                end

                ERASE: begin
                    prev_valid[c] <= 1'b0;             // re-set in DRAW if still alive
                    if (c == N_CORES-1) begin c <= 0; sub <= 0; st <= DRAW; end
                    else c <= c + 1'b1;
                end

                DRAW: case (sub)
                    2'd0: begin alive_r <= (peek_data != 32'd0); sub <= 2'd1; end
                    2'd1: begin px_r <= peek_data[7:0];          sub <= 2'd2; end
                    default: begin                              // sub 2: peek_data = pos_y
                        if (alive_r) begin
                            prev_xy[c]                  <= {peek_data[7:0], px_r};
                            prev_valid[c]               <= 1'b1;
                            acc                         <= acc + 8'd1;
                        end
                        sub <= 2'd0;
                        if (c == N_CORES-1) begin
                            st <= IDLE; done <= 1'b1;
                            alive_count <= acc + (alive_r ? 8'd1 : 8'd0);
                        end
                        else c <= c + 1'b1;
                    end
                endcase
                default: st <= IDLE;
            endcase
        end
        if (fb_we) fb[fb_waddr] <= fb_wdata;
    end
endmodule