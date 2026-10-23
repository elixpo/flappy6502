; Graphics test: a still Flappy Bird scene in landscape 320x240.
; Sky, one pipe pair with caps and shading, striped ground, and the 12x12 bird.
; Nothing moves yet; this checks colours, shapes and the sprite on real hardware.

        .setcpu "6502"
        .segment "CODE"
        .include "lcd.inc"
        .include "gfx.inc"

GROUND_Y = 200                  ; ground starts here (40 px tall)
PIPE_X   = 200                  ; pipe body left edge
PIPE_W   = 26
CAP_W    = 30                   ; caps stick out 2 px each side
CAP_H    = 12
GAP_TOP  = 70                   ; gap between the pipes: y 70..139
GAP_BOT  = 140

        .segment "CODE"

reset:  sei
        cld
        ldx #$FF
        txs
        jsr lcd_init

; sky
        fill_rect 0, 0, LCD_W, GROUND_Y, C_SKY

; ground: grass edge, dark grass line, then dirt with a darker band
        fill_rect 0, GROUND_Y,     LCD_W, 4,  C_GRASS
        fill_rect 0, GROUND_Y + 4, LCD_W, 2,  C_GRASS_DK
        fill_rect 0, GROUND_Y + 6, LCD_W, 34, C_DIRT
        fill_rect 0, GROUND_Y + 20, LCD_W, 3, C_DIRT_DK

; top pipe body (y 0 .. GAP_TOP-CAP_H-1), drawn as shaded vertical strips
        fill_rect PIPE_X,      0, 1,  GAP_TOP - CAP_H, C_PIPE_EDGE
        fill_rect PIPE_X + 1,  0, 4,  GAP_TOP - CAP_H, C_PIPE_LT
        fill_rect PIPE_X + 5,  0, 15, GAP_TOP - CAP_H, C_PIPE
        fill_rect PIPE_X + 20, 0, 5,  GAP_TOP - CAP_H, C_PIPE_DK
        fill_rect PIPE_X + 25, 0, 1,  GAP_TOP - CAP_H, C_PIPE_EDGE
; top cap
        fill_rect PIPE_X - 2,  GAP_TOP - CAP_H, CAP_W, CAP_H, C_PIPE_EDGE
        fill_rect PIPE_X - 1,  GAP_TOP - CAP_H + 1, 4,  CAP_H - 2, C_PIPE_LT
        fill_rect PIPE_X + 3,  GAP_TOP - CAP_H + 1, 18, CAP_H - 2, C_PIPE
        fill_rect PIPE_X + 21, GAP_TOP - CAP_H + 1, 6,  CAP_H - 2, C_PIPE_DK

; bottom cap
        fill_rect PIPE_X - 2,  GAP_BOT, CAP_W, CAP_H, C_PIPE_EDGE
        fill_rect PIPE_X - 1,  GAP_BOT + 1, 4,  CAP_H - 2, C_PIPE_LT
        fill_rect PIPE_X + 3,  GAP_BOT + 1, 18, CAP_H - 2, C_PIPE
        fill_rect PIPE_X + 21, GAP_BOT + 1, 6,  CAP_H - 2, C_PIPE_DK
; bottom pipe body (GAP_BOT+CAP_H .. GROUND_Y-1)
        fill_rect PIPE_X,      GAP_BOT + CAP_H, 1,  GROUND_Y - GAP_BOT - CAP_H, C_PIPE_EDGE
        fill_rect PIPE_X + 1,  GAP_BOT + CAP_H, 4,  GROUND_Y - GAP_BOT - CAP_H, C_PIPE_LT
        fill_rect PIPE_X + 5,  GAP_BOT + CAP_H, 15, GROUND_Y - GAP_BOT - CAP_H, C_PIPE
        fill_rect PIPE_X + 20, GAP_BOT + CAP_H, 5,  GROUND_Y - GAP_BOT - CAP_H, C_PIPE_DK
        fill_rect PIPE_X + 25, GAP_BOT + CAP_H, 1,  GROUND_Y - GAP_BOT - CAP_H, C_PIPE_EDGE

; the bird
        set16 x0, 80
        set16 y0, 100
        jsr draw_bird

halt:   jmp halt

irq:
nmi:    rti

        .segment "VECTORS"
        .word nmi, reset, irq
