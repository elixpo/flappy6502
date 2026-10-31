; flappy1k: Flappy Bird in 1 KiB of 6502 code, colour, for the breadboard R6502 +
; ST7789 hardware of flappy_bb (SCL bit-banged on LCD latch pin 13). No firmware:
; every byte that runs (LCD init, SPI, drawing, game) is in this 1 KiB.
; Linked into $FC00-$FFFF by rom1k.cfg: the build fails if it does not fit.
;
; Play: power on, the scene draws (about 14 s at 1 MHz), press the button to start.
; Each press flaps. Score top left. Hit a pipe, the ground or the top: game over;
; press again to restart.
;
; How:
;  - 12-bit colour; a colour is turned once into its 12 latch values, then each
;    pixel is 12 unrolled bit pairs (13 cycles a bit); everything is drawn as runs
;  - landscape 320x240, the display's fixed area = left 64 columns (bird, score), the
;    other 256 columns scroll in hardware, ground and all; only pipe columns are
;    redrawn as they come back round at the right edge
;  - pipes every 64 px: the 256-line ring holds 4 pipe slots; all position maths 8-bit
;  - zero page cleared at reset: every variable starts at 0, gap 0 = "no pipe"

        .setcpu "6502"

LAT   = $8000                   ; latch: bit0 SDA, bit1 SCL, bit2 DC, bit3 CS
GAP   = 68                      ; vertical opening
BX    = 52                      ; bird columns 52-63 (right edge of the fixed area)
BW    = 12                      ; bird size
BH    = 11

; colour numbers: offsets into pal
C_SKY  = 0
C_BLK  = 2
C_WHT  = 6
C_PD   = 12                     ; pipe outline
C_PL   = 14                     ; pipe light / grass light
C_PM   = 16                     ; pipe body / grass
C_PS   = 18                     ; pipe shade
C_DIRT = 20
C_DTOP = 22

tmp   = $00                     ; send: byte being shifted
dcv   = $01                     ; 0 = command, 4 = data
tmp2  = $02
s     = $03                     ; scroll position in the 256-line ring
yh    = $04                     ; bird y (top row)
vh    = $05                     ; bird speed, rows per frame (the NMI sets -7)
oy    = $06                     ; where the bird is drawn
rng   = $07
score = $08                     ; BCD
klo   = $09                     ; run length: klo + 256 * (khi - 1)
khi   = $0A
lastc = $0B                     ; colour now in tab
t0    = $0C
t1    = $0D
row   = $0E
cnt   = $0F
w     = $10                     ; window: x0h x0l x1h x1l y0h y0l y1h y1l
cg    = $20                     ; gap of the pipe in each slot (0 = none)
pg    = $24                     ; gap of the previous pipe in that slot
gap   = $28
ph    = $29                     ; pipe column pair 0-7
rr    = $2A
ci    = $2B
bc    = $2C
ft    = $2D
sb    = $2E
f0    = $2F
f1    = $30
tab   = $40                     ; 12 latch values (SCL low) of the current colour

        .segment "CODE"

reset:  cld                     ; (any stack pointer works: the stack wraps in page 1)
        ldx #0
        txa
@z:     sta 0,x                 ; clear the zero page
        inx
        bne @z
        dec lastc               ; no colour loaded yet
init:   ldy itab,x              ; table: count, command, data...; 0 ends
        beq boot
        sty row
        inx
        lda itab,x
        jsr cmd
@d:     dec row
        beq @n
        inx
        lda itab,x
        jsr dat
        beq @d                  ; always (send returns Z = 1)
@n:     inx
        jsr delay
        beq init                ; always

; ---- the scene: sky, grass, dirt (the ground scrolls with the pipes) ----
boot:   lda #1                  ; window: the whole screen
        sta w+2
        lda #63
        sta w+3
        lda #239
        sta w+7
        jsr win
        lda #C_SKY              ; rows 0-159
        ldx #0
        ldy #160 * 320 / 256
        jsr run
        lda #C_PD               ; rows 160-161: dark line
        ldx #<640
        ldy #>640 + 1
        jsr run
        lda #8                  ; rows 162-169: diagonal stripes
        sta rr
@sr:    lda #2                  ; 2 x 160 pixels
        sta bc
@h:     lda #160
        sta cnt
@p:     lda ci
        clc
        adc rr
        and #8
        lsr
        lsr
        adc #C_PL               ; C_PL or C_PM
        jsr px
        inc ci
        dec cnt
        bne @p
        dec bc
        bne @h
        dec rr
        bne @sr
        lda #C_PS               ; rows 170-171
        ldx #<640
        ldy #>640 + 1
        jsr run
        lda #C_DTOP             ; row 172
        ldx #<320
        ldy #>320 + 1
        jsr run
        lda #C_DIRT             ; rows 173-239
        ldx #<(67 * 320)
        ldy #>(67 * 320) + 1
        jsr run
        lda #72
        sta yh
        jsr bird
        jsr score2

; ---- game over: wait for a press, then a new game ----
dead:   lda #0
        sta vh
@w:     jsr rnd                 ; press timing seeds the gaps
        lda vh                  ; the NMI sets vh: a press
        beq @w
        lda #0
        sta score
        jsr score2
        jsr bgap                ; start inside the gap if a pipe is at the edge,
        adc #26                 ; else at row 26
        sta yh

; ---- one frame ----
loop:   lda vh                  ; gravity: +1 row/frame each frame, falling capped at 6
        cmp #6
        beq @y
        inc vh
@y:     lda yh
        clc
        adc vh
        sta yh
        cmp #160 - BH
        bcs dead                ; ground, or above the top (wraps round)

        jsr bgap                ; pipe at the edge of the fixed area?
        beq @col
        eor #$FF
        adc yh                  ; yh - gap (- 1 at phase 0, where C = 0)
        cmp #GAP - BH + 1
        bcs dead                ; not inside the gap
        cpy #14                 ; last two columns of the pipe: scored
        bne @col
        sed
        lda score
        adc #0                  ; C = 1 here
        sta score
        cld
        jsr score2
        jsr bgap                ; X = slot, Y = phase again

@col:   inc s                   ; scroll two columns: lines s and s+1 leave the
        inc s                   ; left edge and come back at the right edge
        tya
        bne @old
        jsr rnd                 ; phase 0: a new pipe for this slot
        and #63
        adc #16
        ldy cg,x
        sty pg,x
        sta cg,x
        lda #0
@old:   cmp #16
        bcc @pipe
        lda #44                 ; no pipe: wait about as long as one takes
        jsr delay
        beq @bird               ; always
@pipe:  lsr
        sta ph
        lda cg,x
        sta gap
        jsr pipe

@bird:  lda yh
        cmp oy
        beq :+
        jsr bird
:       lda #$37                ; VSCRSADD: first scroll line = 64 + s
        jsr cmd
        lda s
        clc
        adc #64
        pha
        lda #0
        rol
        jsr dat
        pla
        jsr dat
        jmp loop

; ---- drawing ----

; two pipe columns (lines s-2, s-1) for pair ph, gap row gap: body, cap, sky, cap, body
pipe:   lda s
        clc
        adc #62                 ; old s + 64
        sta w+1
        tax
        inx
        stx w+3
        lda #0
        rol
        sta w
        sta w+2
        lda #0
        sta w+5
        lda #159
        sta w+7
        jsr win
        ldx ph
        lda body,x
        pha
        lda gap
        sec
        sbc #8
        asl
        tax
        pla
        jsr run1
        jsr cap
        lda #C_SKY
        ldx #GAP * 2
        jsr run1
        jsr cap
        ldx ph
        lda body,x
        pha
        lda #160 - GAP - 8
        sec
        sbc gap
        asl
        tax
        pla
        jmp run1
cap:    ldx ph
        lda capc,x
        ldx #16
        jmp run1

; the bird: rows min(oy, yh) .. max(oy, yh) + BH - 1 of columns BX..BX+11
bird:   lda #BX
        sta w+1
        lda #BX + BW - 1
        sta w+3
        lda #0
        sta w
        sta w+2
        lda yh
        ldx oy
        cmp oy
        bcs :+
        ldx yh
        lda oy
:       stx w+5
        stx row
        clc
        adc #BH - 1
        sta w+7
        lda yh
        sta oy
        jsr win
@r:     lda row
        sec
        sbc yh
        cmp #BH
        bcs @sky
        asl                     ; 6 bytes a sprite row
        sta sb
        asl
        adc sb
        sta sb
        lda #BW / 2
        sta bc
@b:     ldy sb
        lda sprite,y
        sta ft
        lsr
        lsr
        lsr
        lsr
        asl
        jsr px
        lda ft
        and #15
        asl
        jsr px
        inc sb
        dec bc
        bne @b
        beq @n
@sky:   lda #C_SKY
        ldx #BW
        jsr run1
@n:     lda row
        inc row
        cmp w+7
        bne @r
        rts

; the score: two digits at x 4 and 14, rows 6-20
score2: lda score
        lsr
        lsr
        lsr
        lsr
        ldx #4
        jsr digit
        lda score
        and #15
        ldx #14
; digit A (3x5 font, 3x scale) in a 10x15 window at column X
digit:  stx w+1
        pha
        txa
        clc
        adc #9
        sta w+3
        lda #0
        sta w
        sta w+2
        lda #6
        sta w+5
        lda #20
        sta w+7
        pla
        asl
        tay
        lda font,y              ; f1:f0 = the 15 bits, shifted out from bit 15
        sta f0
        lda font+1,y
        sta f1
        jsr win
        lda #5                  ; 5 font rows
        sta rr
@fr:    lda #0                  ; next 3 bits
        ldx #3
@e:     asl f0
        rol f1
        rol
        dex
        bne @e
        asl
        asl
        asl
        asl
        asl
        sta sb
        lda #3                  ; each font row 3 times
        sta row
@rep:   lda sb
        sta ft
        lda #3
        sta bc
@b:     asl ft
        lda #C_SKY
        bcc :+
        lda #C_WHT
:       ldx #3
        jsr run1
        dec bc
        bne @b
        lda #C_SKY
        jsr px
        dec row
        bne @rep
        dec rr
        bne @fr
        rts

; ---- pixels ----

px:     ldx #1                  ; one pixel of colour A
run1:   ldy #1                  ; X pixels (0 = 256) of colour A
; klo + 256 * (khi - 1) pixels of colour A: X = klo, Y = khi
run:    stx klo
        sty khi
        cmp lastc
        beq fill
        sta lastc
        tax                     ; colour -> 12 latch values (SDA = bit, SCL low)
        lda pal,x
        sta t1
        lda pal+1,x
        sta t0
        ldy #0
@c:     asl t0
        rol t1
        lda #4
        adc #0
        sta tab,y
        iny
        cpy #12
        bne @c
fill:   ldx #0                  ; one pixel: 2 x 6 unrolled bits
@h:
        .repeat 6, i
        lda tab+i,x
        sta LAT                 ; SDA, SCL low
        ora #2
        sta LAT                 ; SCL high: the panel samples SDA
        .endrepeat
        txa
        eor #6
        tax
        bne @h
        dec klo
        bne fill
        dec khi
        bne fill
        rts

win:    lda #$2A                ; CASET, RASET from w, then RAMWR
        jsr cmd
        ldx #0
        jsr w4
        lda #$2B
        jsr cmd
        jsr w4
        lda #$2C
        jmp cmd

w4:     jsr w2                  ; send w[x], w[x+1], w[x+2], w[x+3]
w2:     jsr w1
w1:     lda w,x
        inx
        ; fall through
dat:    ldy #4
        .byte $2C               ; BIT abs: skips the next ldy
cmd:    ldy #0
        sty dcv
        bne send                ; data: same CS frame
        sty LAT                 ; command: SCL low, then CS high, so each command
        ldy #8                  ; starts a new frame (as in the working driver)
        sty LAT
send:   sta tmp                 ; A out MSB first: 2 latch stores per bit
        ldy #8
@b:     lda dcv
        asl tmp
        adc #0
        sta LAT                 ; SDA, SCL low
        ora #2
        sta LAT                 ; SCL high: the panel samples SDA
        dey
        bne @b
        rts                     ; Y = 0, Z = 1, C = 0

; ---- game helpers ----

; gap of the pipe at the first scrolling column (Z = 1: none); X = slot, Y = phase
bgap:   lda s
        pha
        asl                     ; X = s >> 6
        rol
        rol
        and #3
        tax
        pla
        and #63
        tay
        cmp #16
        lda #0
        bcs @r
        cpy #1                  ; phase 0: not re-drawn yet, still the current pipe
        lda pg,x
        bcs @r
        lda cg,x
@r:     rts

rnd:    lda rng                 ; 8-bit shift generator; starts fine from 0
        asl
        bcs :+
        eor #$F5
:       sta rng
        rts

; wait A x 1280 cycles (A = 0: 256 x)
delay:  sta tmp2
@o:     dey
        bne @o
        dec tmp2
        bne @o
        rts

; ---- data ----

itab:   .byte 1, $00                    ; NOP, then a wait: the panel leaves reset
        .byte 1, $11                    ; SLPOUT
        .byte 2, $3A, $53               ; COLMOD 12 bit
        .byte 2, $36, $60               ; MADCTL landscape
        .byte 7, $33, 0, 64, 1, 0, 0, 0 ; VSCRDEF: 64 fixed, 256 scrolling, 0
        .byte 1, $21                    ; INVON (IPS panel)
        .byte 1, $29                    ; DISPON
        .byte 0

; 12-bit colours, stored left-aligned: RG, B0
pal:    .byte $4C, $C0          ;  0 sky
        .byte $00, $00          ;  2 black
        .byte $FC, $20          ;  4 yellow
        .byte $FF, $F0          ;  6 white
        .byte $F6, $20          ;  8 orange
        .byte $FE, $90          ; 10 cream
        .byte $34, $20          ; 12 pipe outline
        .byte $9E, $50          ; 14 pipe light, grass light
        .byte $7B, $30          ; 16 pipe body, grass
        .byte $58, $20          ; 18 pipe shade
        .byte $DC, $80          ; 20 dirt
        .byte $C9, $50          ; 22 dirt top

; pipe column pairs 0-7, left to right: caps are 2 px wider than the body each side
capc:   .byte C_PD, C_PL, C_PL, C_PM, C_PM, C_PM, C_PS, C_PD
body:   .byte C_SKY, C_PD, C_PL, C_PM, C_PM, C_PS, C_PD, C_SKY

; 12x11 bird, 4 bits a pixel (colour / 2): 0 sky 1 black 2 yellow 3 white 4 orange 5 cream
sprite: .byte $00, $00, $11, $11, $10, $00
        .byte $00, $11, $22, $21, $31, $00
        .byte $01, $22, $22, $13, $33, $10
        .byte $15, $55, $22, $13, $31, $31
        .byte $15, $55, $52, $13, $31, $31
        .byte $12, $55, $52, $21, $33, $31
        .byte $01, $22, $22, $21, $44, $44
        .byte $00, $12, $22, $14, $11, $11
        .byte $00, $01, $22, $21, $44, $41
        .byte $00, $00, $11, $22, $11, $10
        .byte $00, $00, $00, $11, $10, $00

; 3x5 digits, 15 bits each (rows top to bottom, MSB first)
font:   .word %1111011011011110         ; 0
        .word %0101100100101110
        .word %1110011111001110
        .word %1110010110011110
        .word %1011011110010010
        .word %1111001110011110
        .word %1111001111011110
        .word %1110010010010010
        .word %1111011111011110
        .word %1111011110011110

nmi:    pha                     ; flap: -7 rows/frame
        lda #$F9
        sta vh
        pla
irq:    rti

        .segment "VECTORS"
        .word nmi, reset, irq
