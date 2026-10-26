; ST7789P3 driver for the "auto-clock" SPI (stage 7 wiring), or with BITBANG defined,
; for the stage-4 wiring (SCL from the latch, U5 pin 13; no SCL gate chip).
;
; Hardware: the U5 latch still holds SDA/DC/CS (bits 0, 2, 3) and loads on every write
; to $8000-$BFFF. A write to $A000-$BFFF ALSO pulses SCL high during that write cycle,
; which makes the panel sample the latch value from the PREVIOUS write. So one store
; = clock out the previous bit + latch the next one.
;
; Protocol: between transfers the latch holds a value with CS = 1 (the "flush" value).
; A transfer is a run of stores to SPI (each clocks the bit before it; the first one
; clocks the CS-high value, which the panel ignores), ended by flush: one more store
; to SPI (clocks the last real bit) and then FLUSH written to LAT (CS goes high while
; SCL is low).
;
; Landscape 320x240 (MADCTL $60). Uses zero page $00-$1F.

LAT     = $8000                 ; latch only (no clock)
SCL     = $02                   ; latch bit 1 (bit-bang mode only: U5 pin 13)
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

; ---- reset the panel and run the init table (same sequence as the ESP32 oreoWare
;      driver for this module: SmartElex LHS200KP-IF05 / ST7789P3) ----
lcd_init:
        lda #0                  ; command mode, SCL/SDA low (used by flush)
        sta dcbit
        lda #FLUSH              ; CS high: resets the panel's bit counter
        sta LAT
        jsr delay
        lda #0                  ; cp+1 = table index (cmd/dat/delay clobber X and Y)
        sta cp+1
@next:  ldx cp+1
        lda init_tab,x
        inc cp+1
        cmp #$FF
        beq @done
        jsr cmd
        ldx cp+1                ; number of data bytes
        inc cp+1
        lda init_tab,x          ; (load last: the branch tests this value)
        sta cp
        beq @wait
@dat:   ldx cp+1
        lda init_tab,x
        inc cp+1
        jsr dat
        dec cp
        bne @dat
@wait:  ldx cp+1                ; then wait this many x ~131 ms (at 1.25 MHz)
        inc cp+1
        lda init_tab,x
        sta cp
        beq @next
@w:     jsr delay
        dec cp
        bne @w
        jmp @next
@done:  jmp flush

; cmd, number of data bytes, data..., wait units (~131 ms each at 1.25 MHz); $FF ends
init_tab:
        .byte $01, 0, 2                         ; SWRESET            (ESP32: 150 ms)
        .byte $11, 0, 4                         ; SLPOUT             (ESP32: 500 ms)
        .byte $3A, 1, $55, 0                    ; COLMOD 16 bit RGB565
        .byte $36, 1, $60, 0                    ; MADCTL landscape 320x240
        .byte $B2, 5, $0C, $0C, $00, $33, $33, 0 ; PORCTRL porch
        .byte $C6, 1, $1F, 0                    ; FRCTRL2 ~39 Hz refresh
        .byte $C0, 1, $2C, 0                    ; LCMCTRL
        .byte $C2, 1, $01, 0                    ; VDVVRHEN
        .byte $C3, 1, $12, 0                    ; VRHS
        .byte $C4, 1, $20, 0                    ; VDVS
        .byte $BB, 1, $20, 0                    ; VCOMS
        .byte $2A, 4, $00, $00, $01, $3F, 0     ; CASET 0..319
        .byte $2B, 4, $00, $00, $00, $EF, 0     ; RASET 0..239
        .byte $21, 0, 1                         ; INVON (IPS)        (ESP32: 10 ms)
        .byte $13, 0, 1                         ; NORON              (ESP32: 10 ms)
        .byte $29, 0, 1                         ; DISPON             (ESP32: 100 ms)
        .byte $FF

; ---- one byte as a command / as data. Clobbers A, X, Y ----
cmd:
.ifdef BITBANG
        pha                     ; like the ESP32: every command starts a new CS frame
        jsr flush
        pla
.endif
        ldx #0
        stx dcbit
        jmp sendb
dat:    ldx #DC
        stx dcbit
; A = byte; sends it MSB first, then flushes. ~120 cycles.
.ifdef BITBANG
sendb:  sta tmp                 ; bit-bang: SCL is latch bit 1, toggled in software
        .repeat 8
        asl tmp
        lda dcbit
        adc #0                  ; SDA = C
        sta LAT                 ; data, SCL low
        ora #SCL
        sta LAT                 ; SCL rising edge
        .endrepeat
        rts
.else
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
        jmp flush
.endif

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
; The caller ends the whole pixel stream with: jsr flush
emit:   tax
        lda run_lo,x
        sta vec
        lda run_hi,x
        sta vec+1
.ifdef BITBANG
        ldx #DC                 ; data 0, SCL low
        ldy #DC | SCL           ; data 0, SCL high
.else
        ldx #DC                 ; data bit 0
        ldy #DC | SDA           ; data bit 1
.endif
        jmp (vec)

; One routine per colour: 16 stores per pixel (stx = 0 bit, sty = 1 bit), ~72 cycles.
.macro  colour_run n
        .ident(.sprintf("run%d", n)):
        .repeat 16, i
.ifdef BITBANG
        .if (.ident(.sprintf("GCOL_%d", n)) >> (15 - i)) & 1
        lda #DC | SDA
        sta LAT
        lda #DC | SDA | SCL
        sta LAT
        .else
        stx LAT
        sty LAT
        .endif
.else
        .if (.ident(.sprintf("GCOL_%d", n)) >> (15 - i)) & 1
        sty SPI
        .else
        stx SPI
        .endif
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

; End a transfer: one more clocked store (clocks the last real bit; latches a
; CS-low dummy), then raise CS with a latch-only write, so CS never changes
; while SCL is high.
.ifdef BITBANG
flush:  lda dcbit               ; end the CS frame: SCL low first, then CS high
        sta LAT
        lda #FLUSH
        sta LAT
        rts
.else
flush:  lda #DC
        sta SPI
        lda #FLUSH
        sta LAT
        rts
.endif

; ---- ~164k cycles: 131 ms at 1.25 MHz. Clobbers X, Y ----
delay:  ldy #$80
        ldx #0
@d:     dex
        bne @d
        dey
        bne @d
        rts
