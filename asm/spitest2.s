; Diagnostic for the stage-7 auto-clock SPI wiring. Three 80x80 squares on noise:
;   LEFT   red    - every byte sent on its own (dat: CS goes high after each byte)
;   MIDDLE green  - fast runs (emit: one store per bit, CS high only at the end)
;   RIGHT  blue   - one emit per pixel (like the bird's slow path)
; Then the CPU halts. Tell which squares appear.

        .setcpu "6502"
        .segment "CODE"
        .include "gfx.inc"
        .include "lcd2.inc"

px      = $20                   ; 16-bit pixel counter
rr      = $22

reset:  sei
        cld
        ldx #$FF
        txs
        jsr lcd_init

; LEFT: red, byte by byte
        lda #20
        ldx #99
        jsr setwin
        lda #<6400
        sta px
        lda #>6400
        sta px+1
@l:     lda #$F8
        jsr dat
        lda #$00
        jsr dat
        lda px
        bne :+
        dec px+1
:       dec px
        lda px
        ora px+1
        bne @l

; MIDDLE: green, 80 runs of 80 pixels
        lda #120
        ldx #199
        jsr setwin
        lda #80
        sta rr
@m:     lda #80
        sta cnt
        lda #CI_GRASS
        jsr emit
        dec rr
        bne @m
        jsr flush

; RIGHT: blue-ish (pipe dark), one emit per pixel
        lda #220
        ldx #299
        jsr setwin
        lda #<6400
        sta px
        lda #>6400
        sta px+1
@r:     lda #1
        sta cnt
        lda #CI_PIPE_DK
        jsr emit
        lda px
        bne :+
        dec px+1
:       dec px
        lda px
        ora px+1
        bne @r
        jsr flush

halt:   jmp halt

; window x A..X, y 80..159
setwin: sta x0
        stx x1
        lda #0
        sta x0+1
        sta x1+1
        sta y0+1
        sta y1+1
        lda #80
        sta y0
        lda #159
        sta y1
        jmp window

nmi:
irq:    rti

        .segment "VECTORS"
        .word nmi, reset, irq
