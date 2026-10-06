// gpu_regs.vh -- CPU-side register map for the GPU peripheral.
// Based on section 9 of the GPU host contract, plus the spawn and program
// ports the CPU also needs. Change offsets here only; everything else
// includes this file.
//
// Data bus map:
//   0x0000_0000 - 0x0000_0FFF  data RAM (4 KB)
//   0x4000_0000 - 0x4000_00FF  GPU registers (below)
// Registers are word-aligned: decode addr[7:2].

`define GPU_BASE          32'h4000_0000

// ---- from contract section 9 ----
`define GPU_PLAYER_X      8'h00  // W  -> host_addr 0
`define GPU_PLAYER_Y      8'h04  // W  -> host_addr 1
`define GPU_SHOT_X        8'h08  // W  -> host_addr 2
`define GPU_SHOT_Y        8'h0C  // W  -> host_addr 3
`define GPU_START         8'h10  // W  write 1 -> pulse start
`define GPU_STATUS        8'h14  // R  bit0 = all_done, bit1 = render_busy
`define GPU_RENDER        8'h18  // W  write 1 -> pulse render_start

// ---- additions (contract sections 3 and 4 need these) ----
`define GPU_SPAWN_CORE    8'h1C  // W  core index 0..31
`define GPU_SPAWN_ADDR    8'h20  // W  local word 0..4 (pos_x,pos_y,vel_x,vel_y,alive)
`define GPU_SPAWN_DATA    8'h24  // W  writing this pulses spawn_we
`define GPU_PROG_ADDR     8'h28  // W  ROM word 0..255
`define GPU_PROG_DATA     8'h2C  // W  writing this pulses prog_we

// STATUS bit positions
`define GPU_STATUS_DONE   0
`define GPU_STATUS_BUSY   1
`define GPU_STATUS_DROPPED 2     // sticky: a GPU write was ignored; write to STATUS clears it

// ---- shot slots (the GPU entity program checks four shots) ----
// slot k: x at 0x30 + 8k, y at 0x34 + 8k  ->  host words 2+2k and 3+2k
// slot 0 is the same shot as GPU_SHOT_X / GPU_SHOT_Y above.
// An unused slot must be parked at 1000 so it can never hit anything.
`define GPU_SHOT0_X       8'h30
`define GPU_SHOT0_Y       8'h34
`define GPU_SHOT1_X       8'h38
`define GPU_SHOT1_Y       8'h3C
`define GPU_SHOT2_X       8'h40
`define GPU_SHOT2_Y       8'h44
`define GPU_SHOT3_X       8'h48
`define GPU_SHOT3_Y       8'h4C