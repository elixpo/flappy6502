; flappy512: a complete Flappy Bird in under 512 bytes of 6502 code, for the same
; breadboard R6502 + ST7789 hardware as flappy_bb (SCL bit-banged on LCD latch pin 13).
; Linked into $FE00-$FFFF by rom512.cfg: the build fails if it does not fit.
;
; Play: power on, the screen clears (about 13 s at 1 MHz), press the button to start.
; Each press flaps. Pass a pipe: the score bar (top left) grows by one block. Hit a
; pipe, the ground or the top: game over; press again to restart.
;
; Tricks:
;  - two colours, each pixel all ones or all zeros, so every bit is two fixed latch
;    writes (no shifting); one fill routine draws every rectangle
;  - landscape 320x240, the display's fixed area = left 64 columns (bird, score), the
;    other 256 columns scroll in hardware; the bird never needs a sideways redraw
;  - pipes every 64 px: the 256-line ring holds 4 pipe slots, so lines that are sky
;    stay sky forever; all position maths is 8-bit
;  - zero page cleared at reset: every variable starts at 0, gap 0 = "no pipe"

        .setcpu "6502"

LAT   = $8000                   ; latch: bit0 SDA, bit1 SCL, bit2 DC, bit3 CS
BLK   = 5                       ; data, SDA 1: all-ones pixels (black: the IPS panel
WHT   = 4                       ; runs without INVON); data, SDA 0: white
GAP   = 64                      ; vertical opening
BX    = 56                      ; bird columns 56-63 (right edge of the fixed area)

tmp   = $00                     ; send: byte being shifted
dcv   = $01                     ; 0 = command, 4 = data
tmp2  = $02
s     = $03                     ; scroll position in the 256-line ring
yh    = $04                     ; bird y (top row)
vh    = $05                     ; bird speed, rows per frame
oy    = $06                     ; where the bird is drawn
rng   = $08
score = $09
k     = $0B
cnt   = $0C
fc    = $0D                     ; fill colour: BLK or WHT
row   = $0F
w     = $10                     ; window: x0h x0l x1h x1l y0h y0l y1h y1l
cg    = $20                     ; gap of the pipe in each slot (0 = none)
pg    = $24                     ; gap of the previous pipe in that slot

        .segment "CODE"

reset:  cld                     ; (any stack pointer works: the stack wraps in page 1)
        ldx #0
        txa
@z:     sta 0,x                 ; clear the zero page
        inx
        bne @z
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

boot:   lda #1                  ; window: the whole screen
        sta w+2
        lda #63
        sta w+3
        lda #BLK
        sta fc
        ldy #0                  ; 10 x 8192 pixels black, one RAMWR stream
        ldx #239
        lda #0
        jsr rows
        lda #9
        sta cnt
@c:     jsr fill
        dec cnt
        bne @c
        dec fc                  ; white ground line, rows 160-163
        ldy #160
        ldx #163
        lda #40
        jsr rows

; ---- game over: wait for a press, then a new game ----
dead:   lda #0
        sta vh
        sta score
@w:     jsr rnd                 ; press timing seeds the gaps
        lda vh                  ; the NMI sets vh: a press
        beq @w
        lda #4                  ; erase the score bar
        jsr col8
        lda #BLK
        sta fc
        ldy #0
        ldx #159
        lda #40
        jsr rows
        dec fc                  ; every frame starts with fc = WHT
        jsr bgap                ; start inside the gap if a pipe is at the edge,
        adc #24                 ; else at row 24
        sta yh

; ---- one frame ----
loop:   lda vh                  ; gravity: +1 row/frame each frame, falling capped at 6
        cmp #6                  ; (the NMI sets vh = -7: a flap)
        beq @y
        inc vh
@y:     lda yh
        clc
        adc vh
        sta yh
        cmp #152
        bcs dead                ; ground, or above the top (wraps round)

        jsr bgap                ; pipe at the edge of the fixed area?
        beq @col
        eor #$FF
        adc yh                  ; yh - gap (- 1 at phase 0, where C = 0)
        cmp #GAP - 7
        bcs dead                ; not inside the gap
        cpy #14                 ; last two columns of the pipe: scored
        bne @col
        lda #4                  ; score bar: one more 8x8 block
        jsr col8
        ldy score
        tya
        adc #8                  ; C = 1 here: 9 rows per point
        sta score
        jsr b8
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
        bcc @pipe               ; always
@old:   cmp #16
        bcc @pipe
        lda #58                 ; no pipe: wait about as long as one takes
        jsr delay
        beq @bird               ; always
@pipe:  lda cg,x                ; two columns white, then the gap black
        pha
        lda s
        adc #62                 ; old s + 64 (C = 0 here)
        sta w+1
        tax
        inx
        stx w+3
        lda #0
        rol
        sta w
        sta w+2
        ldy #0
        ldx #159
        lda #10
        jsr rows
        inc fc
        pla
        tay
        adc #GAP - 1            ; C = 0 after rows
        tax
        lda #4
        jsr rows

@bird:  lda #BX                 ; erase the bird, draw it at the new row
        jsr col8
        lda #BLK
        sta fc
        ldy oy
        jsr b8
        dec fc
        ldy yh
        sty oy
        jsr b8

        lda #$37                ; VSCRSADD: first scroll line = 64 + s
        jsr cmd
        lda s
        adc #64                 ; C = 0 after send
        pha
        lda #0
        rol
        jsr dat
        pla
        jsr dat
        jmp loop

; ---- helpers ----

; window columns A..A+7 (A < 249)
col8:   sta w+1
        clc
        adc #7
        sta w+3
        lda #0
        sta w
        sta w+2
        rts

; 8x8 block at row Y, columns from col8, colour fc
b8:     tya
        clc
        adc #7
        tax
        lda #2
; rows Y..X of the window, A = 32-pixel units to send, colour fc
rows:   sty w+5
        stx w+7
; fill the window w with colour fc: A x 32 pixels (A = 0: 8192). The panel wraps
; inside the window, so sending more than fits is harmless.
rect:   sta k
        jsr win                 ; leaves Y = 0
fill:   ldx fc                  ; X = SCL low, A = SCL high, same SDA
        txa
        ora #2
@i:     stx LAT
        sta LAT
        stx LAT
        sta LAT
        dey
        bne @i
        dec k
        bne @i
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

; gap of the pipe at the first scrolling column (Z = 1: none); Y = its phase
bgap:   lda s
        jsr slot
        tay
        cmp #16
        lda #0
        bcs @r
        cpy #1                  ; phase 0: not re-drawn yet, still the current pipe
        lda pg,x
        bcs @r
        lda cg,x
@r:     rts

; X = slot (A >> 6), A = phase (A & 63)
slot:   pha
        asl
        rol
        rol
        and #3
        tax
        pla
        and #63
        rts

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

itab:   .byte 1, $00                    ; NOP, then a wait: the panel leaves reset
        .byte 1, $11                    ; SLPOUT
        .byte 2, $3A, $55               ; COLMOD 16 bit
        .byte 2, $36, $60               ; MADCTL landscape
        .byte 7, $33, 0, 64, 1, 0, 0, 0 ; VSCRDEF: 64 fixed, 256 scrolling, 0
        .byte 1, $29                    ; DISPON
        .byte 0

nmi:    pha                     ; flap: -7 rows/frame
        lda #$F9
        sta vh
        pla
irq:    rti

        .segment "VECTORS"
        .word nmi, reset, irq
