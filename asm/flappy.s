; Flappy Bird for the R6502 + ST7789 (landscape 320x240, bit-banged SPI).
;
; Play: the game starts on reset with the bird hovering; the first flap starts it.
; The button (NMI) flaps. Hit a pipe or the ground -> your score appears in the
; middle; press again (after ~0.4 s) to restart.
;
; How it stays fast enough:
;  - The world moves with the ST7789 hardware scroll (VSCRSADD), no pixels copied.
;    Each frame, the STEP columns that scrolled off the left edge reappear at the
;    right edge and are redrawn as the new world columns.
;  - Pipes repeat every 160 px = half the 320 px scroll ring, so a column that
;    wraps around was sky before and is sky again (nothing to draw), and pipe
;    columns always land on the same memory lines (0-29 and 160-189). A pipe
;    column only needs the rows around the old and the new gap redrawn.
;  - Every colour has its 16 latch values precomputed in RAM (ctab), so a pixel
;    is 16 x (lda ctab+i,x / sta LATCH / ora #SCL / sta LATCH) = 14 cycles per bit.
;
; If the pipes move to the RIGHT on the real screen, set SCROLL_DIR = -1.

        .setcpu "6502"
        .segment "CODE"
        .include "lcd.inc"
        .include "gfx.inc"

; ---- tuning ----
SCROLL_DIR = 1
STEP     = 2                    ; scroll pixels per frame
GROUND_Y = 200                  ; first ground row
GAP      = 80                   ; vertical gap between pipes
GAP_MIN  = 24                   ; gap top = GAP_MIN + (random & 63)
PERIOD   = 160                  ; pipe spacing; must be 320 / 2
PIPE_W   = 30                   ; pipe width incl. caps
BIRD_X   = 80                   ; bird screen column (left edge)
BIRD_Y0  = 100                  ; start row
BIRD_MAX = GROUND_Y - BIRD_H    ; lowest row before the ground
FLAP_V   = $FB80                ; -4.5 px/frame (8.8 fixed point)
GRAV     = $0066                ; +0.4 px/frame^2
MAXV     = $0600                ; terminal speed 6 px/frame
COL_WAIT = 24                   ; delay_col loops: makes a sky column cost about a pipe column
SCORE_Y  = 60
NOPIPE   = $FF

ctab    = $0200                 ; 16 colours x 16 latch values

; ---- zero page ($00-$2F belong to lcd.inc) ----
flap    = $30                   ; incremented by the NMI (button)
scr     = $32                   ; scroll position 0..319 (16-bit)
yf      = $34                   ; bird y, 8.8: yf = fraction
yp      = $35                   ;              yp = pixel row
vy      = $36                   ; bird speed, 8.8 signed (16-bit)
oy      = $38                   ; row the bird was drawn at
cgap    = $39                   ; gap top of the pipe in slot 0 / 1 (NOPIPE = none)
pgap    = $3B                   ; gap of the previous pipe in that slot
rng     = $3D
score   = $3E                   ; BCD, 2 bytes
lx      = $40                   ; logical (memory) column, 16-bit
phase   = $42                   ; lx mod 160
slot    = $43                   ; lx / 160
r0      = $44                   ; pipe column: rows r0..r1-1 are redrawn
r1      = $45
gt      = $46                   ; pipe column: gap top
gp      = $47                   ; pipe column: previous gap top
segi    = $48
bptr    = $4A                   ; 16-bit
ncol    = $4C
c0      = $4D
pp      = $4E                   ; last phase seen at the bird's left edge (scoring)
sx      = $50                   ; screen x, 16-bit
rw      = $52                   ; rect width
ry0     = $53                   ; rect rows ry0..ry1
ry1     = $54
rcol    = $55                   ; rect colour id
rows    = $56
j       = $57
part    = $58
tz      = $59
si      = $5A
fidx    = $5B
fbits   = $5C
cellr   = $5D
cellc   = $5E
dx      = $5F                   ; 16-bit
bnd     = $60                   ; 10 segment boundaries
scol    = $6A                   ; 9 segment colours
dig     = $73                   ; 3 score digits

; =========================================================================

reset:  sei
        cld
        ldx #$FF
        txs
        lda #0
        sta flap
        lda #$A5
        sta rng
        jsr lcd_init
        jsr build_ctab

        lda #$33                ; VSCRDEF: TFA 0, VSA 320, BFA 0 (whole screen scrolls)
        jsr cmd
        lda #0
        jsr spi_byte
        lda #0
        jsr spi_byte
        lda #>320
        jsr spi_byte
        lda #<320
        jsr spi_byte
        lda #0
        jsr spi_byte
        lda #0
        jsr spi_byte
        lda #0
        sta scr
        sta scr+1
        jsr send_scroll

        fill_rect 0, 0,            LCD_W, GROUND_Y, C_SKY
        fill_rect 0, GROUND_Y,     LCD_W, 4,  C_GRASS
        fill_rect 0, GROUND_Y + 4, LCD_W, 2,  C_GRASS_DK
        fill_rect 0, GROUND_Y + 6, LCD_W, 34, C_DIRT
        fill_rect 0, GROUND_Y + 20, LCD_W, 3, C_DIRT_DK

; ---- new game: bird hovers until the first flap ----
newgame:
        lda #BIRD_Y0
        sta yp
        sta oy
        lda #0
        sta yf
        sta vy
        sta vy+1
        sta score
        sta score+1
        lda #NOPIPE
        sta cgap
        sta cgap+1
        sta pgap
        sta pgap+1
        lda #<BIRD_X
        sta sx
        lda #>BIRD_X
        sta sx+1
        jsr to_lx
        jsr ph_of
        lda phase
        sta pp
        jsr put_bird
        lda #0
        sta flap
@wait:  jsr rnd                 ; the press timing seeds the random gaps
        lda flap
        beq @wait
        jmp doflap

; ---- one frame ----
play:   lda flap
        beq noflap
doflap: lda #0
        sta flap
        lda #<FLAP_V
        sta vy
        lda #>FLAP_V
        sta vy+1
noflap: jsr physics

        clc                     ; scroll the world STEP pixels
        lda scr
        adc #STEP
        sta scr
        lda scr+1
        adc #0
        sta scr+1
        beq :+
        lda scr
        cmp #<320
        bcc :+
        sbc #<320               ; carry is set
        sta scr
        lda #0
        sta scr+1
:       jsr send_scroll

        jsr new_cols
        jsr erase_bird
        jsr put_bird
        lda yp
        sta oy
        jsr rnd
        jsr collide
        bcs died
        jsr scorechk
        jmp play

died:   jsr show_score
        jsr delay
        jsr delay
        jsr delay
        lda #0
        sta flap
@wait:  jsr rnd
        lda flap
        beq @wait
        jsr cleanup
        jmp newgame

; =========================================================================
; Physics: vy += GRAV (capped), y += vy, stay between row 0 and BIRD_MAX.
physics:
        clc
        lda vy
        adc #<GRAV
        sta vy
        lda vy+1
        adc #>GRAV
        sta vy+1
        bmi @move               ; rising: no cap
        cmp #>MAXV
        bcc @move
        lda #<MAXV
        sta vy
        lda #>MAXV
        sta vy+1
@move:  clc
        lda yf
        adc vy
        sta yf
        lda yp
        adc vy+1
        sta yp
        cmp #$E0                ; wrapped above the top -> clamp to 0
        bcc @low
        lda #0
        sta yp
        sta yf
        sta vy
        sta vy+1
        rts
@low:   cmp #BIRD_MAX + 1
        bcc @ok
        lda #BIRD_MAX
        sta yp
@ok:    rts

; Collision: C = 1 if the bird box (BIRD_X..+17, yp..yp+17) hits a pipe or the ground.
collide:
        lda yp
        cmp #BIRD_MAX
        bcs @yes
        lda #<(BIRD_X + BIRD_W - 1)
        sta sx
        lda #>(BIRD_X + BIRD_W - 1)
        sta sx+1
        jsr to_lx
        jsr ph_of
        lda phase
        cmp #PIPE_W
        bcc @pipe
        lda #<BIRD_X
        sta sx
        lda #>BIRD_X
        sta sx+1
        jsr to_lx
        jsr ph_of
        lda phase
        cmp #PIPE_W
        bcs @no
@pipe:  ldx slot
        lda cgap,x
        cmp #NOPIPE
        beq @no
        sta tz
        lda yp                  ; top above the gap?
        cmp tz
        bcc @yes
        lda tz                  ; bottom below the gap?
        clc
        adc #GAP
        sta tz
        lda yp
        clc
        adc #BIRD_H - 1
        cmp tz
        bcs @yes
@no:    clc
        rts
@yes:   sec
        rts

; Score +1 when a pipe's last column passes the bird's left edge.
scorechk:
        lda #<BIRD_X
        sta sx
        lda #>BIRD_X
        sta sx+1
        jsr to_lx
        jsr ph_of
        lda phase
        cmp #PIPE_W
        bcc @save
        lda pp
        cmp #PIPE_W
        bcs @save
        ldx slot
        lda cgap,x
        cmp #NOPIPE
        beq @save
        sed
        clc
        lda score
        adc #1
        sta score
        lda score+1
        adc #0
        sta score+1
        cld
@save:  lda phase
        sta pp
        rts

; =========================================================================
; Draw the STEP new columns at the right edge (memory lines that just wrapped).
new_cols:
        lda #0
        sta j
@col:   lda #<(320 - STEP)
        clc
        adc j
        sta sx
        lda #>(320 - STEP)
        adc #0
        sta sx+1
        jsr to_lx
        jsr ph_of
        lda phase
        bne @notnew
        ldx slot                ; a new pipe enters in this slot
        lda cgap,x
        sta pgap,x
        jsr rnd
        and #63
        clc
        adc #GAP_MIN
        sta cgap,x
@notnew:
        lda phase
        cmp #PIPE_W
        bcs @sky
        ldx slot
        lda cgap,x
        cmp #NOPIPE
        beq @sky
        sta gt
        lda pgap,x
        sta gp
        jsr pipe_col
        jmp @next
@sky:   jsr delay_col           ; sky stays sky; just keep the frame time even
@next:  inc j
        lda j
        cmp #STEP
        bne @col
        rts

; Draw one pipe column at memory line lx, phase 0..29, gap top gt.
; Only rows that can differ from the previous pipe (gap gp) are sent;
; gp = NOPIPE means the line was sky, so the whole column is drawn.
pipe_col:
        lda gp
        cmp #NOPIPE
        bne @union
        lda #0
        sta r0
        lda #GROUND_Y
        sta r1
        jmp @bounds
@union: lda gt                  ; r0 = min(gt, gp) - 12
        cmp gp
        bcc :+
        lda gp
:       sec
        sbc #12
        sta r0
        lda gt                  ; r1 = max(gt, gp) + GAP + 12
        cmp gp
        bcs :+
        lda gp
:       clc
        adc #GAP + 12
        sta r1
@bounds:
        lda #0                  ; body | edge | cap | edge | sky | edge | cap | edge | body
        sta bnd
        lda gt
        sec
        sbc #12
        sta bnd+1
        lda gt
        sec
        sbc #11
        sta bnd+2
        lda gt
        sec
        sbc #1
        sta bnd+3
        lda gt
        sta bnd+4
        clc
        adc #GAP
        sta bnd+5
        clc
        adc #1
        sta bnd+6
        clc
        adc #10
        sta bnd+7
        clc
        adc #1
        sta bnd+8
        lda #GROUND_Y
        sta bnd+9
        ldx phase
        lda body_id,x
        sta scol
        sta scol+8
        lda cap_id,x
        sta scol+2
        sta scol+6
        lda #ID_PIPE_EDGE
        sta scol+1
        sta scol+3
        sta scol+5
        sta scol+7
        lda #ID_SKY
        sta scol+4

        lda lx                  ; window: 1 column, rows r0..r1-1
        sta x0
        sta x1
        lda lx+1
        sta x0+1
        sta x1+1
        lda r0
        sta y0
        ldx r1
        dex
        stx y1
        lda #0
        sta y0+1
        sta y1+1
        jsr window

        lda #0
        sta segi
@seg:   ldx segi
        lda bnd,x               ; start = max(bnd[i], r0)
        cmp r0
        bcs :+
        lda r0
:       sta tz
        lda bnd+1,x             ; end = min(bnd[i+1], r1)
        cmp r1
        bcc :+
        lda r1
:       sec
        sbc tz
        bcc @next               ; end < start
        beq @next               ; empty
        tay
        lda scol,x
        tax
        jsr emit
@next:  inc segi
        lda segi
        cmp #9
        bne @seg
        rts

; Pipe profile by phase 0..29: colour of the body rows and of the cap rows.
body_id:
        .byte ID_SKY, ID_SKY, ID_PIPE_EDGE
        .byte ID_PIPE_LT, ID_PIPE_LT, ID_PIPE_LT, ID_PIPE_LT
        .repeat 15
        .byte ID_PIPE
        .endrepeat
        .byte ID_PIPE_DK, ID_PIPE_DK, ID_PIPE_DK, ID_PIPE_DK, ID_PIPE_DK
        .byte ID_PIPE_EDGE, ID_SKY, ID_SKY
cap_id:
        .byte ID_PIPE_EDGE
        .byte ID_PIPE_LT, ID_PIPE_LT, ID_PIPE_LT, ID_PIPE_LT
        .repeat 18
        .byte ID_PIPE
        .endrepeat
        .byte ID_PIPE_DK, ID_PIPE_DK, ID_PIPE_DK, ID_PIPE_DK, ID_PIPE_DK, ID_PIPE_DK
        .byte ID_PIPE_EDGE

; =========================================================================
; Bird: erase what the scroll and the vertical move left behind, then redraw.
erase_bird:
        lda #ID_SKY
        sta rcol
        lda #<(BIRD_X - STEP)   ; strip the scroll uncovered on the left
        sta sx
        lda #>(BIRD_X - STEP)
        sta sx+1
        lda #STEP
        sta rw
        lda oy
        sta ry0
        clc
        adc #BIRD_H - 1
        sta ry1
        jsr srect
        lda yp
        cmp oy
        beq @done
        bcc @up
        lda oy                  ; moved down: old top rows oy..yp-1
        sta ry0
        ldx yp
        dex
        stx ry1
        jmp @do
@up:    lda yp                  ; moved up: old bottom rows yp+18..oy+17
        clc
        adc #BIRD_H
        sta ry0
        lda oy
        clc
        adc #BIRD_H - 1
        sta ry1
@do:    lda #<BIRD_X
        sta sx
        lda #>BIRD_X
        sta sx+1
        lda #BIRD_W - STEP
        sta rw
        jmp srect
@done:  rts

; Draw the bird at screen column BIRD_X, row yp; split if it wraps past line 319.
put_bird:
        lda #<BIRD_X
        sta sx
        lda #>BIRD_X
        sta sx+1
        jsr to_lx
        lda #0
        sta c0
        jsr room
        bcs @whole
        sta ncol                ; part 1: lx .. 319
        jsr bird_part
        lda ncol
        sta c0
        lda #BIRD_W
        sec
        sbc ncol
        sta ncol
        lda #0                  ; part 2: 0 ..
        sta lx
        sta lx+1
        jmp bird_part
@whole: lda #BIRD_W
        sta ncol
        jmp bird_part

; columns c0..c0+ncol-1 of the sprite at memory line lx
bird_part:
        lda lx
        sta x0
        clc
        adc ncol
        sta x1
        lda lx+1
        sta x0+1
        adc #0
        sta x1+1
        lda x1                  ; x1 = x0 + ncol - 1
        bne :+
        dec x1+1
:       dec x1
        lda yp
        sta y0
        clc
        adc #BIRD_H - 1
        sta y1
        lda #0
        sta y0+1
        sta y1+1
        jsr window
        lda #<bird16
        clc
        adc c0
        sta bptr
        lda #>bird16
        adc #0
        sta bptr+1
        lda #BIRD_H
        sta rows
@row:   ldy #0
@px:    lda (bptr),y
        tax
        .repeat 16, i
        lda ctab+i,x
        sta LATCH
        ora #SCL
        sta LATCH
        .endrepeat
        iny
        cpy ncol
        jne @px
        lda bptr
        clc
        adc #BIRD_W
        sta bptr
        bcc :+
        inc bptr+1
:       dec rows
        jne @row
        rts

; =========================================================================
; Score (game over): up to 3 big digits, 3x5 cells of 6 px, centred.
show_score:
        lda score+1
        and #$0F
        sta dig
        lda score
        lsr
        lsr
        lsr
        lsr
        sta dig+1
        lda score
        and #$0F
        sta dig+2
        ldx #0                  ; skip leading zeros (keep at least one digit)
        lda dig
        bne @go
        inx
        lda dig+1
        bne @go
        inx
@go:    stx si
        lda xs_tab,x
        sta dx
        lda #0
        sta dx+1
@dig:   ldx si
        lda dig,x
        jsr draw_digit
        lda dx
        clc
        adc #24
        sta dx
        inc si
        lda si
        cmp #3
        bne @dig
        rts

xs_tab: .byte 127, 139, 151     ; x of the first digit for 3, 2, 1 digits

draw_digit:
        sta tz                  ; font index = digit * 5
        asl
        asl
        clc
        adc tz
        sta fidx
        lda #ID_SCORE
        sta rcol
        lda #6
        sta rw
        lda #0
        sta cellr
@r:     ldx fidx
        lda font,x
        sta fbits
        inc fidx
        lda #0
        sta cellc
@c:     lda fbits
        and #4
        beq @skip
        ldx cellc
        lda dx
        clc
        adc mul6,x
        sta sx
        lda dx+1
        adc #0
        sta sx+1
        ldx cellr
        lda mul6,x
        clc
        adc #SCORE_Y
        sta ry0
        clc
        adc #5
        sta ry1
        jsr srect
@skip:  asl fbits
        inc cellc
        lda cellc
        cmp #3
        bne @c
        inc cellr
        lda cellr
        cmp #5
        bne @r
        rts

mul6:   .byte 0, 6, 12, 18, 24
font:   .byte 7,5,5,5,7, 2,6,2,2,7, 7,1,7,4,7, 7,1,7,1,7, 5,5,7,1,1
        .byte 7,4,7,1,7, 7,4,7,5,7, 7,1,1,1,1, 7,5,7,5,7, 7,5,7,1,7

; After game over: pipes (memory lines 0-29, 160-189), the score and the bird -> sky.
cleanup:
        lda #ID_SKY
        sta rcol
        lda #0
        sta ry0
        lda #GROUND_Y - 1
        sta ry1
        lda #PIPE_W
        sta part
        lda #0
        sta lx
        sta lx+1
        jsr lrect
        lda #PERIOD
        sta lx
        jsr lrect
        lda #127
        sta sx
        lda #0
        sta sx+1
        lda #66
        sta rw
        lda #SCORE_Y
        sta ry0
        lda #SCORE_Y + 29
        sta ry1
        jsr srect
        lda #<BIRD_X
        sta sx
        lda #>BIRD_X
        sta sx+1
        lda #BIRD_W
        sta rw
        lda yp
        sta ry0
        clc
        adc #BIRD_H - 1
        sta ry1
        jmp srect

; =========================================================================
; Helpers

; lx = (scr + sx) mod 320
to_lx:  clc
        lda scr
        adc sx
        sta lx
        lda scr+1
        adc sx+1
        sta lx+1
        beq @ok
        cmp #2
        bcs @sub
        lda lx
        cmp #<320
        bcc @ok
@sub:   lda lx
        sec
        sbc #<320
        sta lx
        lda lx+1
        sbc #>320
        sta lx+1
@ok:    rts

; slot = lx / 160, phase = lx mod 160
ph_of:  lda lx+1
        bne @high
        lda lx
        cmp #PERIOD
        bcs @s1
        sta phase
        lda #0
        sta slot
        rts
@s1:    sbc #PERIOD             ; carry set
        sta phase
        lda #1
        sta slot
        rts
@high:  lda lx                  ; 256..319 -> phase = lx - 160 = low + 96
        clc
        adc #256 - PERIOD
        sta phase
        lda #1
        sta slot
        rts

; A = 320 - lx if that is < BIRD_W... general: C = 1 if a width of BIRD_W fits
; before line 320, else C = 0 and A = columns left before the wrap.
room:   lda #<320
        sec
        sbc lx
        sta tz
        lda #>320
        sbc lx+1
        bne @fits               ; >= 256 columns left
        lda tz
        cmp #BIRD_W
        bcs @fits
        clc
        rts
@fits:  sec
        rts

; Fill a screen rectangle: x sx..sx+rw-1 (wraps), rows ry0..ry1, colour rcol.
srect:  jsr to_lx
        lda #<320
        sec
        sbc lx
        sta tz
        lda #>320
        sbc lx+1
        bne @one
        lda tz
        cmp rw
        bcs @one
        sta part                ; part up to line 319, then the rest from 0
        jsr lrect
        lda #0
        sta lx
        sta lx+1
        lda rw
        sec
        sbc part
        sta part
        jmp lrect
@one:   lda rw
        sta part
        ; fall through

; Fill memory lines lx..lx+part-1, rows ry0..ry1 with rcol.
lrect:  lda lx
        sta x0
        clc
        adc part
        sta x1
        lda lx+1
        sta x0+1
        adc #0
        sta x1+1
        lda x1
        bne :+
        dec x1+1
:       dec x1
        lda ry0
        sta y0
        lda ry1
        sta y1
        lda #0
        sta y0+1
        sta y1+1
        jsr window
        lda ry1
        sec
        sbc ry0
        sta rows
        inc rows
@r:     ldx rcol
        ldy part
        jsr emit
        dec rows
        bne @r
        rts

; Send Y pixels of colour X (a ctab offset). ~229 cycles per pixel.
emit:
@p:     .repeat 16, i
        lda ctab+i,x
        sta LATCH
        ora #SCL
        sta LATCH
        .endrepeat
        dey
        jne @p
        rts

; ctab[id*16 + bit] = latch value for bit 15-bit of colour id (data mode, CS low)
build_ctab:
        ldy #0
        ldx #0
@c:     lda gcol_hi,y
        sta tmp
        lda gcol_lo,y
        sta tmp2
        lda #16
        sta tz
@b:     asl tmp2
        rol tmp
        lda #DC
        adc #0
        sta ctab,x
        inx
        dec tz
        bne @b
        iny
        cpy #NCOL
        bne @c
        rts

; VSCRSADD = scr (or 320 - scr when the panel scrolls the other way)
send_scroll:
        lda #$37
        jsr cmd
.if SCROLL_DIR > 0
        lda scr+1
        jsr spi_byte
        lda scr
        jmp spi_byte
.else
        lda scr
        ora scr+1
        bne :+
        lda #0
        jsr spi_byte
        lda #0
        jmp spi_byte
:       lda #<320
        sec
        sbc scr
        sta tz
        lda #>320
        sbc scr+1
        jsr spi_byte
        lda tz
        jmp spi_byte
.endif

; 8-bit LFSR
rnd:    lda rng
        asl
        bcc :+
        eor #$1D
:       sta rng
        rts

; About the time one pipe column takes, so frames run at an even speed.
delay_col:
        ldy #COL_WAIT
        ldx #0
:       dex
        bne :-
        dey
        bne :-
        rts

nmi:    inc flap
irq:    rti

        .segment "VECTORS"
        .word nmi, reset, irq
