; ---- entity-update program, 4 shot slots ----
; runs once per tick, per thread. register map:
;   R0  = zero/base register (re-established fresh every run)
;   R1  = pos_x        R2 = pos_y
;   R3  = vel_x         R4 = vel_y
;   R5  = alive flag (1=alive, 0=dead)
;   R6  = wrap mask (255 = 0xFF, screen is 256x256)
;   R7  = shot_x         R8 = shot_y        (the shot slot being checked)
;   R9  = dx (|pos_x-shot_x|)   R10 = dy (|pos_y-shot_y|)
;   R11 = collision radius
; local mem:  0=pos_x 1=pos_y 2=vel_x 3=vel_y 4=alive
; global mem (raw ISA addr, rebased to mem_ctrl's own space in hardware):
;             64=player_x 65=player_y
;             shot slot k: x = 66+2k, y = 67+2k   (k = 0..3, so ISA addr 66..73)
; An unused slot must hold a coordinate that can never hit (the host parks it at 1000).
; An enemy dies if it is within the radius of ANY of the four shots.

        MOVI  R0, 0                ; fresh zero/base register this tick

        LDR   R5, [R0+4]           ; R5 = alive
        CMP   R5, R0
        BEQ   DONE                 ; dead -- skip the whole update

        ; -- alive: read this entity's state --
        LDR   R1, [R0+0]           ; pos_x
        LDR   R2, [R0+1]           ; pos_y
        LDR   R3, [R0+2]           ; vel_x
        LDR   R4, [R0+3]           ; vel_y

        ; -- integrate position --
        ADD   R1, R1, R3
        ADD   R2, R2, R4

        ; -- wrap at screen bounds (256x256) --
        MOVI  R6, 255
        AND   R1, R1, R6
        AND   R2, R2, R6

        MOVI  R11, 8               ; collision radius (tunable)
        ; -- shot slot 0 --
        LDR   R7, [R0+66]          ; shot_x
        LDR   R8, [R0+67]          ; shot_y
        CMP   R1, R7
        BGT   DX0_POS
        SUB   R9, R7, R1           ; else: shot_x >= pos_x
        CMP   R9, R9
        BEQ   DX0_DONE
DX0_POS: SUB   R9, R1, R7
DX0_DONE:
        CMP   R2, R8
        BGT   DY0_POS
        SUB   R10, R8, R2
        CMP   R10, R10
        BEQ   DY0_DONE
DY0_POS: SUB   R10, R2, R8
DY0_DONE:
        CMP   R9, R11
        BGT   MISS0              ; dx > radius -> miss
        CMP   R10, R11
        BGT   MISS0              ; dy > radius -> miss
        CMP   R9, R9               ; hit: jump to the kill below
        BEQ   HIT
MISS0:
        ; -- shot slot 1 --
        LDR   R7, [R0+68]          ; shot_x
        LDR   R8, [R0+69]          ; shot_y
        CMP   R1, R7
        BGT   DX1_POS
        SUB   R9, R7, R1           ; else: shot_x >= pos_x
        CMP   R9, R9
        BEQ   DX1_DONE
DX1_POS: SUB   R9, R1, R7
DX1_DONE:
        CMP   R2, R8
        BGT   DY1_POS
        SUB   R10, R8, R2
        CMP   R10, R10
        BEQ   DY1_DONE
DY1_POS: SUB   R10, R2, R8
DY1_DONE:
        CMP   R9, R11
        BGT   MISS1              ; dx > radius -> miss
        CMP   R10, R11
        BGT   MISS1              ; dy > radius -> miss
        CMP   R9, R9               ; hit: jump to the kill below
        BEQ   HIT
MISS1:
        ; -- shot slot 2 --
        LDR   R7, [R0+70]          ; shot_x
        LDR   R8, [R0+71]          ; shot_y
        CMP   R1, R7
        BGT   DX2_POS
        SUB   R9, R7, R1           ; else: shot_x >= pos_x
        CMP   R9, R9
        BEQ   DX2_DONE
DX2_POS: SUB   R9, R1, R7
DX2_DONE:
        CMP   R2, R8
        BGT   DY2_POS
        SUB   R10, R8, R2
        CMP   R10, R10
        BEQ   DY2_DONE
DY2_POS: SUB   R10, R2, R8
DY2_DONE:
        CMP   R9, R11
        BGT   MISS2              ; dx > radius -> miss
        CMP   R10, R11
        BGT   MISS2              ; dy > radius -> miss
        CMP   R9, R9               ; hit: jump to the kill below
        BEQ   HIT
MISS2:
        ; -- shot slot 3 --
        LDR   R7, [R0+72]          ; shot_x
        LDR   R8, [R0+73]          ; shot_y
        CMP   R1, R7
        BGT   DX3_POS
        SUB   R9, R7, R1           ; else: shot_x >= pos_x
        CMP   R9, R9
        BEQ   DX3_DONE
DX3_POS: SUB   R9, R1, R7
DX3_DONE:
        CMP   R2, R8
        BGT   DY3_POS
        SUB   R10, R8, R2
        CMP   R10, R10
        BEQ   DY3_DONE
DY3_POS: SUB   R10, R2, R8
DY3_DONE:
        CMP   R9, R11
        BGT   WRITEBACK              ; dx > radius -> miss
        CMP   R10, R11
        BGT   WRITEBACK              ; dy > radius -> miss
HIT:
        ; -- hit: mark dead --
        MOVI  R5, 0
        STR   R5, [R0+4]

WRITEBACK:
        STR   R1, [R0+0]           ; write updated pos_x back
        STR   R2, [R0+1]           ; write updated pos_y back

DONE:   HALT