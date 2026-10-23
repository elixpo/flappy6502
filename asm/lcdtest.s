; Stage 4: ST7789P3 bring-up over bit-banged SPI through the U5 latch.
;
; Latch $8000: bit0 = SDA, bit1 = SCL, bit2 = DC (1 = data), bit3 = CS (low = selected).
; LCD RST is tied to +5V (the module loads the CPU /RES line too much); the
; init starts with a software reset (SWRESET) instead.
;
; What you should see (625 kHz CPU clock):
;   ~0.5 s   backlight on, screen still dark/garbage (init running)
;   then     random-noise picture = display on, init worked
;   ~17 s    screen wipes to black from top to bottom (fast fill)
;   ~6 s     five 48x48 squares appear in the middle: RED GREEN BLUE WHITE YELLOW
;   then     the CPU halts; the picture stays.
;
; If the colours are wrong: white/black swapped -> change INVON ($21) to INVOFF ($20);
; red and blue swapped -> change MADCTL data $00 to $08.

        .setcpu "6502"

LATCH   = $8000
SDA     = $01
SCL     = $02
DC      = $04
CS      = $08

tmp     = $00                   ; byte being shifted out
dcbit   = $01                   ; 0 = command, DC = data
flags   = $02                   ; init table: bit7 = delay after
x0      = $03                   ; window, x 0..239
x1      = $04
y0      = $05                   ; window, y 0..319 (16-bit)
y1      = $07
hcnt    = $09                   ; rows left (16-bit)
w       = $0B                   ; pixels per row
colhi   = $0C                   ; RGB565 colour
collo   = $0D
idx     = $0E

; bne to a label that may be out of branch range
.macro  jne target
        beq :+
        jmp target
:
.endmacro

        .segment "CODE"

reset:  sei
        cld
        ldx #$FF
        txs
        lda #CS                 ; CS high: deselect, resets the panel's SPI bit counter
        sta LATCH
        jsr delay               ; let the panel power up / come out of reset
        lda #0                  ; CS low, SCL low; stays selected from now on
        sta dcbit
        sta LATCH

; ---- init table: cmd, (count | $80 = delay after), data... ; $FF ends ----
        ldx #0
inext:  lda init_tab,x
        inx
        cmp #$FF
        beq idone
        jsr cmd
        lda init_tab,x
        inx
        sta flags
        and #$7F
        beq inodat
        tay
idat:   lda init_tab,x
        inx
        jsr spi_byte
        dey
        bne idat
inodat: bit flags
        bpl inext
        jsr delay
        jmp inext
idone:

; ---- clear the whole screen to black (fast path: only SCL toggles) ----
        lda #0
        sta x0
        sta y0
        sta y0+1
        lda #239
        sta x1
        lda #<319
        sta y1
        lda #>319
        sta y1+1
        jsr window
        lda #<320
        sta hcnt
        lda #>320
        sta hcnt+1
        lda #DC                 ; SDA = 0, SCL low
        ldx #DC | SCL           ; SDA = 0, SCL high
crow:   ldy #240
cpix:   .repeat 16              ; one pixel = 16 bits of 0
        sta LATCH
        stx LATCH
        .endrepeat
        dey
        bne cpix
        dec hcnt
        bne crow
        dec hcnt+1
        bpl crow                ; 320 = $0140: rows run out when hcnt+1 wraps

; ---- five 48x48 squares across the middle ----
        lda #0
        sta idx
sq:     ldx idx
        lda sq_x,x
        sta x0
        clc
        adc #47
        sta x1
        lda #136
        sta y0
        lda #183
        sta y1
        lda #0
        sta y0+1
        sta y1+1
        lda sq_hi,x
        sta colhi
        lda sq_lo,x
        sta collo
        jsr fill
        inc idx
        lda idx
        cmp #5
        bne sq

halt:   jmp halt

; ---- set CASET/RASET from x0,x1,y0,y1 and start RAMWR ----
window: lda #$2A
        jsr cmd
        lda #0
        jsr spi_byte
        lda x0
        jsr spi_byte
        lda #0
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

; ---- fill the window x0..x1, y0..y1 with colhi:collo ----
fill:   jsr window
        lda x1
        sec
        sbc x0
        clc
        adc #1
        sta w
        lda y1
        sec
        sbc y0
        sta hcnt
        lda y1+1
        sbc y0+1
        sta hcnt+1
        inc hcnt                ; rows = y1 - y0 + 1
        bne frow
        inc hcnt+1
frow:   ldx w
fpix:   lda colhi
        jsr spi_byte
        lda collo
        jsr spi_byte
        dex
        bne fpix
        lda hcnt
        bne :+
        dec hcnt+1
:       dec hcnt
        lda hcnt
        ora hcnt+1
        bne frow
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

; ---- ~164k cycles: ~260 ms at 625 kHz (>=120 ms even at 1.25 MHz). Keeps X ----
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

init_tab:
        .byte $01, $80          ; SWRESET, wait
        .byte $11, $80          ; SLPOUT, wait
        .byte $3A, 1, $55       ; COLMOD: 16 bits/pixel (RGB565)
        .byte $36, 1, $00       ; MADCTL: portrait, RGB order
        .byte $21, 0            ; INVON (IPS panels need inversion on)
        .byte $13, 0            ; NORON
        .byte $29, $80          ; DISPON, wait
        .byte $FF

sq_x:   .byte 0, 48, 96, 144, 192
sq_hi:  .byte $F8, $07, $00, $FF, $FF   ; red, green, blue, white, yellow
sq_lo:  .byte $00, $E0, $1F, $FF, $E0

irq:
nmi:    rti

        .segment "VECTORS"
        .word nmi, reset, irq
