; ST7789P3 driver: bit-banged SPI through the U5 latch at $8000.
; Landscape 320 x 240 (MADCTL $60). Include from a program; uses zero page $00-$2F.
;
; Latch bits: 0 SDA, 1 SCL, 2 DC (1 = data), 3 CS (low = selected).

LATCH   = $8000
SDA     = $01
SCL     = $02
DC      = $04
CS      = $08

LCD_W   = 320
LCD_H   = 240

tmp     = $00                   ; byte being shifted out
tmp2    = $01
dcbit   = $02                   ; 0 = command, DC = data
flags   = $03
x0      = $04                   ; window, 16-bit each
x1      = $06
y0      = $08
y1      = $0A
wcnt    = $0C                   ; fill counters, 16-bit
hcnt    = $0E
width   = $10
colhi   = $12                   ; current colour (RGB565)
collo   = $13
spos    = $14
cl      = $20                   ; $20-$2F: latch value for each of the 16 colour bits

; bne to a label that may be out of branch range
.macro  jne target
        beq :+
        jmp target
:
.endmacro

; set a 16-bit zero-page variable
.macro  set16 var, value
        lda #<(value)
        sta var
        lda #>(value)
        sta var+1
.endmacro

; fill_rect x, y, w, h, colour  (all constants)
.macro  fill_rect px, py, pw, ph, colour
        set16 x0, px
        set16 x1, px + pw - 1
        set16 y0, py
        set16 y1, py + ph - 1
        lda #>(colour)
        sta colhi
        lda #<(colour)
        sta collo
        jsr fill
.endmacro

; ---- reset the panel and run the init table ----
lcd_init:
        lda #CS                 ; CS high: deselect, resets the panel's SPI bit counter
        sta LATCH
        jsr delay               ; let the panel power up
        lda #0                  ; CS low, SCL low; stays selected from now on
        sta dcbit
        sta LATCH
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
        tay
@dat:   lda init_tab,x
        inx
        jsr spi_byte
        dey
        bne @dat
@nodat: bit flags
        bpl @next
        jsr delay
        jmp @next
@done:  rts

init_tab:
        .byte $01, $80          ; SWRESET, wait
        .byte $11, $80          ; SLPOUT, wait
        .byte $3A, 1, $55       ; COLMOD: 16 bits/pixel (RGB565)
        .byte $36, 1, $60       ; MADCTL: landscape 320x240 (MV|MX). Upside down? use $A0
        .byte $21, 0            ; INVON (IPS panels need inversion on)
        .byte $13, 0            ; NORON
        .byte $29, $80          ; DISPON, wait
        .byte $FF

; ---- CASET/RASET from x0,x1,y0,y1, then RAMWR (left in data mode) ----
window: lda #$2A
        jsr cmd
        lda x0+1
        jsr spi_byte
        lda x0
        jsr spi_byte
        lda x1+1
        jsr spi_byte
        lda x1
        jsr spi_byte
        lda #$2B
        jsr cmd
        lda y0+1
        jsr spi_byte
        lda y0
        jsr spi_byte
        lda y1+1
        jsr spi_byte
        lda y1
        jsr spi_byte
        lda #$2C
        jmp cmd

; ---- fill window x0..x1, y0..y1 with colhi:collo. ~13 cycles per bit ----
fill:   jsr window
        lda colhi               ; precompute the latch value for each colour bit
        sta tmp
        lda collo
        sta tmp2
        ldx #0
@bits:  asl tmp2
        rol tmp                 ; C = next bit, MSB first
        lda #DC
        adc #0                  ; SDA = C
        sta cl,x
        inx
        cpx #16
        bne @bits

        lda x1                  ; width = x1 - x0 + 1
        sec
        sbc x0
        sta width
        lda x1+1
        sbc x0+1
        sta width+1
        inc width
        bne :+
        inc width+1
:       lda y1                  ; hcnt = y1 - y0 + 1
        sec
        sbc y0
        sta hcnt
        lda y1+1
        sbc y0+1
        sta hcnt+1
        inc hcnt
        bne @row
        inc hcnt+1

@row:   lda width
        sta wcnt
        lda width+1
        sta wcnt+1
@pix:   .repeat 16, i
        lda cl+i
        sta LATCH               ; data, SCL low
        ora #SCL
        sta LATCH               ; SCL rising edge
        .endrepeat
        lda wcnt
        bne :+
        dec wcnt+1
:       dec wcnt
        lda wcnt
        ora wcnt+1
        jne @pix
        lda hcnt
        bne :+
        dec hcnt+1
:       dec hcnt
        lda hcnt
        ora hcnt+1
        jne @row
        rts

; ---- draw the 12x12 bird at x0, y0 (palette index 0 = sky) ----
draw_bird:
        lda x0
        clc
        adc #BIRD_W - 1
        sta x1
        lda x0+1
        adc #0
        sta x1+1
        lda y0
        clc
        adc #BIRD_H - 1
        sta y1
        lda y0+1
        adc #0
        sta y1+1
        jsr window
        ldy #0
@px:    lda bird,y
        lsr
        lsr
        lsr
        lsr
        tax
        lda pal_hi,x
        jsr spi_byte
        lda pal_lo,x
        jsr spi_byte
        lda bird,y
        and #$0F
        tax
        lda pal_hi,x
        jsr spi_byte
        lda pal_lo,x
        jsr spi_byte
        iny
        cpy #BIRD_W * BIRD_H / 2
        bne @px
        rts

; ---- send A as a command byte, then switch to data mode ----
cmd:    pha
        lda #0
        sta dcbit
        pla
        jsr spi_byte
        lda #DC
        sta dcbit
        rts

; ---- shift A out MSB first, SPI mode 0. Keeps X and Y. ~20 cycles/bit ----
spi_byte:
        sta tmp
        .repeat 8
        asl tmp                 ; C = next bit
        lda dcbit
        adc #0                  ; SDA = C (dcbit has bit 0 clear)
        sta LATCH               ; data out, SCL low
        ora #SCL
        sta LATCH               ; SCL rising edge: panel samples SDA
        .endrepeat
        rts

; ---- ~164k cycles: 131 ms at 1.25 MHz, 263 ms at 625 kHz. Keeps X ----
delay:  txa
        pha
        ldy #$80
        ldx #0
@d:     dex
        bne @d
        dey
        bne @d
        pla
        tax
        rts
