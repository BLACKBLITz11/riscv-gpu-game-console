# game.asm -- swarm shooter game loop for the RV32I CPU
# The CPU moves the player and up to four shots, fires automatically while the
# fire button is held, and runs one GPU tick per frame.

# GPU registers (offsets from 0x4000_0000) and controller
.equ GPU_PLAYER_X,   0x00
.equ GPU_PLAYER_Y,   0x04
.equ GPU_START,      0x10
.equ GPU_STATUS,     0x14
.equ GPU_RENDER,     0x18
.equ GPU_SPAWN_CORE, 0x1C
.equ GPU_SPAWN_ADDR, 0x20
.equ GPU_SPAWN_DATA, 0x24
.equ GPU_SHOT0_X,    0x30       # shot slot k: x at 0x30 + 8k, y at 0x34 + 8k
.equ GPU_SHOT0_Y,    0x34
.equ CTRL_BUTTONS,   0x100

# button bits (bits 6-7 carry the weapon level - 1, set by the host)
.equ BTN_LEFT,    4
.equ BTN_RIGHT,   8
.equ BTN_FIRE,    16
.equ BTN_RESPAWN, 32            # request a new wave of 32 enemies
.equ LEVEL_SHIFT, 6

# game tuning
.equ N_ENTITIES,    32
.equ PLAYER_Y,      240
.equ PLAYER_SPEED,  5
.equ SHOT_SPEED,    8
.equ FIRE_INTERVAL, 6           # frames between shots while the fire button is held
.equ SLOT_BYTES,    32          # 4 slots x 8 bytes in data RAM (x at +0, y at +4)
.equ X_MIN,         8
.equ X_MAX,         247
.equ PARKED,        1000        # shot coordinate that can never hit (enemies are 0..255)
# frame pacing for real hardware: about (clock_hz / 60 - 800) / 7. Small value for simulation.
.equ FRAME_DELAY,   20

# register use
#   s0 = GPU base        s1 = player_x       s2 = player_y
#   s6 = random state    s7 = entity index   s8 = saved return address
#   s9 = fire cooldown   s10 = buttons       s11 = shot slots in use (weapon level, 1..4)
# data RAM: shot slot k at byte 8k: x at +0, y at +4 (y > 255 means the slot is free)

start:
    lui  s0, 0x40000
    li   s1, 128
    li   s2, PLAYER_Y
    li   s6, 0x2545F491
    li   s9, 0
    li   t4, 0                      # park all four shot slots
    li   t5, PARKED
init_slots:
    sw   t5, 0(t4)
    sw   t5, 4(t4)
    addi t4, t4, 8
    li   t6, SLOT_BYTES
    blt  t4, t6, init_slots
    jal  ra, spawn_wave

# ---- one frame per pass ----
frame:
wait_idle:                          # GPU idle = all_done 1 and render_busy 0
    lw   t0, GPU_STATUS(s0)
    andi t0, t0, 3
    addi t0, t0, -1
    bnez t0, wait_idle

    lw   s10, CTRL_BUTTONS(s0)
    andi t1, s10, BTN_RESPAWN
    beqz t1, no_respawn
    jal  ra, spawn_wave
no_respawn:
    srli s11, s10, LEVEL_SHIFT      # weapon level = bits 7:6 + 1
    andi s11, s11, 3
    addi s11, s11, 1

    andi t1, s10, BTN_LEFT
    beqz t1, no_left
    addi s1, s1, -PLAYER_SPEED
no_left:
    andi t1, s10, BTN_RIGHT
    beqz t1, no_right
    addi s1, s1, PLAYER_SPEED
no_right:
    li   t1, X_MIN                  # keep the player on screen
    bge  s1, t1, x_lo_ok
    mv   s1, t1
x_lo_ok:
    li   t1, X_MAX
    bge  t1, s1, x_hi_ok
    mv   s1, t1
x_hi_ok:

    li   t4, 0                      # move every shot in flight up
move_shots:
    lw   t5, 4(t4)
    li   t6, 255
    blt  t6, t5, shot_idle          # y > 255: slot is free
    addi t5, t5, -SHOT_SPEED
    bge  t5, zero, shot_store
    li   t5, PARKED                 # left the top: free the slot
shot_store:
    sw   t5, 4(t4)
shot_idle:
    addi t4, t4, 8
    li   t6, SLOT_BYTES
    blt  t4, t6, move_shots

    beqz s9, fire_ready             # automatic fire while the button is held
    addi s9, s9, -1
    j    fire_done
fire_ready:
    andi t1, s10, BTN_FIRE
    beqz t1, fire_done
    li   t4, 0
    slli t3, s11, 3                 # only the first (level) slots may be used
find_slot:
    bge  t4, t3, fire_done          # all allowed slots are busy
    lw   t5, 4(t4)
    li   t6, 255
    blt  t6, t5, got_slot           # free slot found
    addi t4, t4, 8
    j    find_slot
got_slot:
    sw   s1, 0(t4)
    addi t5, s2, -12
    sw   t5, 4(t4)
    li   s9, FIRE_INTERVAL
fire_done:

    sw   s1, GPU_PLAYER_X(s0)
    sw   s2, GPU_PLAYER_Y(s0)
    li   t4, 0                      # send all four slots to the GPU
send_shots:
    lw   t5, 0(t4)
    lw   t6, 4(t4)
    add  t2, s0, t4
    sw   t5, GPU_SHOT0_X(t2)
    sw   t6, GPU_SHOT0_Y(t2)
    addi t4, t4, 8
    li   t5, SLOT_BYTES
    blt  t4, t5, send_shots
    li   t1, 1
    sw   t1, GPU_START(s0)

wait_tick:                          # wait for all_done
    lw   t0, GPU_STATUS(s0)
    andi t0, t0, 1
    beqz t0, wait_tick

    li   t1, 1
    sw   t1, GPU_RENDER(s0)

    li   t0, FRAME_DELAY            # software frame pacing
delay:
    addi t0, t0, -1
    bnez t0, delay
    j    frame

# ---- spawn a wave: 32 enemies, x 8..246, y 8..102, vx +-(1..2), vy 0..1 ----
spawn_wave:
    mv   s8, ra
    li   s7, 0
spawn_loop:
    sw   s7, GPU_SPAWN_CORE(s0)

    jal  ra, rng                    # word 0: pos_x
    andi t2, a0, 127
    srli t3, a0, 7
    andi t3, t3, 111
    add  t2, t2, t3
    addi t2, t2, 8
    li   t3, 0
    sw   t3, GPU_SPAWN_ADDR(s0)
    sw   t2, GPU_SPAWN_DATA(s0)

    jal  ra, rng                    # word 1: pos_y
    andi t2, a0, 63
    srli t3, a0, 6
    andi t3, t3, 31
    add  t2, t2, t3
    addi t2, t2, 8
    li   t3, 1
    sw   t3, GPU_SPAWN_ADDR(s0)
    sw   t2, GPU_SPAWN_DATA(s0)

    jal  ra, rng                    # word 2: vel_x = +-(1..2)
    andi t2, a0, 1
    addi t2, t2, 1
    andi t3, a0, 2
    beqz t3, vx_pos
    sub  t2, zero, t2
vx_pos:
    li   t3, 2
    sw   t3, GPU_SPAWN_ADDR(s0)
    sw   t2, GPU_SPAWN_DATA(s0)

    jal  ra, rng                    # word 3: vel_y = 0..1
    andi t2, a0, 1
    li   t3, 3
    sw   t3, GPU_SPAWN_ADDR(s0)
    sw   t2, GPU_SPAWN_DATA(s0)

    li   t2, 1                      # word 4: alive
    li   t3, 4
    sw   t3, GPU_SPAWN_ADDR(s0)
    sw   t2, GPU_SPAWN_DATA(s0)

    addi s7, s7, 1
    li   t0, N_ENTITIES
    blt  s7, t0, spawn_loop
    jalr zero, s8, 0                # return

rng:                                # xorshift32 on s6, result in a0
    slli t1, s6, 13
    xor  s6, s6, t1
    srli t1, s6, 17
    xor  s6, s6, t1
    slli t1, s6, 5
    xor  s6, s6, t1
    mv   a0, s6
    ret