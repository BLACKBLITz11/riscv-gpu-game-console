// vga_scanout.v -- 800x600 @ 60 Hz (40 MHz pixel clock) video output.
// Shows the 256x256 1-bit framebuffer at 2x scale (512x512), centred, white on black.
// Also makes the 60 Hz frame timer (frame_tick / frame_count).
//
// The framebuffer read is registered (pixel valid one clock after fb_x/fb_y),
// so the sync signals and the "inside picture" flag are delayed to match.
// Total pipeline: outputs lag the internal counters by 2 clocks.
module vga_scanout (
    input            clk,          // 40 MHz pixel clock
    input            rst,

    // framebuffer read port (registered read, like gpu_top's fb_pixel)
    output     [7:0] fb_x,
    output     [7:0] fb_y,
    input            fb_pixel,

    // VGA outputs (12-bit colour, positive sync)
    output reg       hsync,
    output reg       vsync,
    output reg [3:0] vga_r,
    output reg [3:0] vga_g,
    output reg [3:0] vga_b,

    // frame timer
    output reg       frame_tick,   // 1-clock pulse at the start of each frame's vertical blanking
    output reg [7:0] frame_count   // +1 every frame (wraps at 256)
);
    localparam H_VIS = 800, H_FP = 40, H_SYNC = 128, H_TOT = 1056;
    localparam V_VIS = 600, V_FP = 1,  V_SYNC = 4,   V_TOT = 628;
    localparam X0 = 144, Y0 = 44;          // top-left corner of the 512x512 picture

    reg [10:0] hc;                         // 0..1055
    reg [9:0]  vc;                         // 0..627

    always @(posedge clk) begin
        if (rst) begin
            hc <= 11'd0; vc <= 10'd0;
        end else if (hc == H_TOT - 1) begin
            hc <= 11'd0;
            vc <= (vc == V_TOT - 1) ? 10'd0 : vc + 10'd1;
        end else begin
            hc <= hc + 11'd1;
        end
    end

    // which framebuffer pixel sits under the beam (2x scale = drop the lowest bit)
    wire [10:0] dx = hc - X0;
    wire [9:0]  dy = vc - Y0;
    assign fb_x = dx[8:1];
    assign fb_y = dy[8:1];

    wire in_img = (hc >= X0) && (hc < X0 + 512) && (vc >= Y0) && (vc < Y0 + 512);
    wire hs_raw = (hc >= H_VIS + H_FP) && (hc < H_VIS + H_FP + H_SYNC);
    wire vs_raw = (vc >= V_VIS + V_FP) && (vc < V_VIS + V_FP + V_SYNC);

    // pipeline stage 1: line the flags up with the framebuffer's registered read
    reg in_d, hs_d, vs_d;
    always @(posedge clk) begin
        in_d <= in_img;
        hs_d <= hs_raw;
        vs_d <= vs_raw;
    end

    // pipeline stage 2: the pixel is valid now; drive the pins
    always @(posedge clk) begin
        hsync <= hs_d;
        vsync <= vs_d;
        vga_r <= (in_d & fb_pixel) ? 4'hF : 4'h0;
        vga_g <= (in_d & fb_pixel) ? 4'hF : 4'h0;
        vga_b <= (in_d & fb_pixel) ? 4'hF : 4'h0;
    end

    // frame timer: one pulse when the visible area ends (start of vertical blanking)
    always @(posedge clk) begin
        if (rst) begin
            frame_tick <= 1'b0; frame_count <= 8'd0;
        end else begin
            frame_tick <= 1'b0;
            if (hc == 0 && vc == V_VIS) begin
                frame_tick  <= 1'b1;
                frame_count <= frame_count + 8'd1;
            end
        end
    end
endmodule