; ST7789P3 driver for the "auto-clock" SPI (stage 7 wiring).
;
; Hardware: the U5 latch still holds SDA/DC/CS (bits 0, 2, 3) and loads on every write
; to $8000-$BFFF. A write to $A000-$BFFF ALSO pulses SCL high during that write cycle,
; which makes the panel sample the latch value from the PREVIOUS write. So one store
; = clock out the previous bit + latch the next one.
;
; Protocol: between transfers the latch holds a value with CS = 1 (the "flush" value).
; A transfer is a run of stores to SPI (each clocks the bit before it; the first one
; clocks the CS-high value, which the panel ignores), ended by one store of the flush
; value, which clocks the last real bit and parks CS high again.
;
; Landscape 320x240 (MADCTL $60). Uses zero page $00-$1F.

LAT     = $8000                 ; latch only (no clock)
SPI     = $A000                 ; latch + SCL pulse
SDA     = $01
DC      = $04
CS      = $08
FLUSH   = CS                    ; parked value: CS high

LCD_W   = 320
LCD_H   = 240

tmp     = $00
dcbit   = $01                   ; 0 = command, DC = data
flags   = $02
x0      = $04                   ; window, 16-bit each
x1      = $06
y0      = $08
y1      = $0A
cnt     = $0C                   ; pixels left in a run
vec     = $0E                   ; jump vector for emit
cp      = $10                   ; code generator pointer

; bne to a label that may be out of branch range
.macro  jne target
        beq :+
        jmp target
:
.endmacro

; ---- reset the panel and run the init table ----
lcd_init:
        lda #FLUSH              ; CS high: resets the panel's bit counter
        sta LAT
        jsr delay
        ldx #0
@next:  lda init_tab,x
        inx
        cmp #$FF
        beq @done
        jsr cmd
        lda init_tab,x
        inx
        sta flags
        and #$7F
        beq @nodat
        sta cp                  ; data byte counter
@dat:   lda init_tab,x
        inx
        stx cp+1
        jsr dat
        ldx cp+1
        dec cp
        bne @dat
@nodat: bit flags
        bpl @next
        stx cp+1
        jsr delay
        ldx cp+1
        jmp @next
@done:  rts

init_tab:
        .byte $01, $80          ; SWRESET, wait
        .byte $11, $80          ; SLPOUT, wait
        .byte $3A, 1, $55       ; COLMOD: 16 bits/pixel (RGB565)
        .byte $36, 1, $60       ; MADCTL: landscape 320x240
        .byte $21, 0            ; INVON
        .byte $13, 0            ; NORON
        .byte $29, $80          ; DISPON, wait
        .byte $FF

; ---- one byte as a command / as data. Clobbers A, X, Y ----
cmd:    ldx #0
        stx dcbit
        jmp sendb
dat:    ldx #DC
        stx dcbit
; A = byte; sends it MSB first, then flushes. ~120 cycles.
sendb:  sta tmp
        ldx dcbit               ; X = bit 0 value, Y = bit 1 value
        ldy dcbit
        iny
        .repeat 8
        asl tmp
        bcc :+
        sty SPI
        bcs :++                 ; always
:       stx SPI
:
        .endrepeat
        lda #FLUSH
        sta SPI
        rts

; ---- CASET/RASET from x0,x1,y0,y1, then RAMWR. Clobbers A, X, Y ----
window: lda #$2A
        jsr cmd
        lda x0+1
        jsr dat
        lda x0
        jsr dat
        lda x1+1
        jsr dat
        lda x1
        jsr dat
window_y:                       ; same column range, new rows
        lda #$2B
        jsr cmd
        lda y0+1
        jsr dat
        lda y0
        jsr dat
        lda y1+1
        jsr dat
        lda y1
        jsr dat
        lda #$2C
        jmp cmd

; ---- send cnt (1..255) pixels of colour index A. Leaves X = $04, Y = $05 ----
; The caller ends the whole pixel stream with: lda #FLUSH / sta SPI
emit:   tax
        lda run_lo,x
        sta vec
        lda run_hi,x
        sta vec+1
        ldx #DC                 ; data bit 0
        ldy #DC | SDA           ; data bit 1
        jmp (vec)

; One routine per colour: 16 stores per pixel (stx = 0 bit, sty = 1 bit), ~72 cycles.
.macro  colour_run n
        .ident(.sprintf("run%d", n)):
        .repeat 16, i
        .if (.ident(.sprintf("GCOL_%d", n)) >> (15 - i)) & 1
        sty SPI
        .else
        stx SPI
        .endif
        .endrepeat
        dec cnt
        jne .ident(.sprintf("run%d", n))
        rts
.endmacro

        .repeat NCOL, n
        colour_run n
        .endrepeat

run_lo: .repeat NCOL, n
        .byte <.ident(.sprintf("run%d", n))
        .endrepeat
run_hi: .repeat NCOL, n
        .byte >.ident(.sprintf("run%d", n))
        .endrepeat

flush:  lda #FLUSH
        sta SPI
        rts

; ---- ~164k cycles: 131 ms at 1.25 MHz. Clobbers X, Y ----
delay:  ldy #$80
        ldx #0
@d:     dex
        bne @d
        dey
        bne @d
        rts
