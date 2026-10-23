; Flappy Bird v2 for the R6502 + ST7789, using the auto-clock SPI (stage 7 wiring).
; Target ~24 frames/s at 1.25 MHz.
;
; Screen (landscape 320x240):
;   x 0-19     fixed HUD strip (never scrolls): live score, 3 digits top to bottom
;   x 20-319   scrolling world, 300 px ring: sky, pipes every 100 px, ground
;
; Play: power on -> bird hovers; press = flap (the first press starts the game).
; Crash -> big score in the middle; ~1 s later a press restarts and flaps at once.
;
; Speed tricks:
;  - world moves by the panel's hardware scroll; only the STEP columns that wrap to
;    the right edge are drawn, and pipe columns only where old and new pipe differ
;  - one store per SPI bit (the write to $A000 makes the clock pulse itself)
;  - the bird (+ STEP sky columns on its left) is compiled at boot into RAM as
;    5760 straight-line stores, ~23k cycles to draw

        .setcpu "6502"
        .segment "CODE"
        .include "gfx.inc"
        .include "lcd2.inc"

; ---- tuning (per frame; ~24 frames/s at 1.25 MHz) ----
STEP     = 2                    ; scroll px per frame (~48 px/s)
GAP      = 80                   ; vertical opening between the pipes
GAP_MIN  = 24                   ; gap top = GAP_MIN + (random & 63)
FLAP_V   = $F680                ; -9.5 px/frame   (8.8 fixed point) ~ -230 px/s
GRAV     = $014D                ; +1.3 px/frame^2               ~ 750 px/s^2
MAXV     = $0B00                ; fall speed cap 11 px/frame (must stay < 18)
COL_WAIT = 6                    ; delay for a skipped column ~ cost of a pipe column

; ---- layout ----
TFA      = 20                   ; fixed HUD width (memory lines 0-19)
RING     = 300                  ; scrolling lines 20-319
PERIOD   = 100                  ; pipe spacing: RING / 3, so wrapped columns match
NSLOT    = 3
PIPE_W   = 30
GROUND_Y = 200
BIRD_X   = 80                   ; bird left edge on screen
BIRD_Y0  = 100
BIRD_MAX = GROUND_Y - BIRD_H
BW2      = BIRD_W + STEP        ; drawn width: STEP sky columns + the bird
SCORE_Y  = 60                   ; big game-over score
NOPIPE   = $FF

BCODE    = $0400                ; compiled bird: 360 px x 16 stores x 3 bytes + rts
BPIX     = $4800                ; the same 20x18 picture as colour indices (slow path)

; ---- zero page ($00-$1F belong to lcd2.inc) ----
flap    = $20                   ; incremented by the NMI (button)
s       = $22                   ; scroll position in the ring 0..299 (16-bit)
yf      = $24                   ; bird y 8.8: fraction
yp      = $25                   ;             pixel row
vy      = $26                   ; 8.8 signed, 16-bit
oy      = $28                   ; row the bird was drawn at
cgap    = $29                   ; 3 slots: gap top of the current pipe (NOPIPE = none)
pgap    = $2C                   ; 3 slots: gap top of the previous pipe
rng     = $2F
score   = $30                   ; BCD, 2 bytes
q       = $32                   ; ring position, 16-bit
phase   = $34
slot    = $35
r0      = $36
r1      = $37
gt      = $38
gp      = $39
segi    = $3A
rw      = $3B
ry0     = $3C
ry1     = $3D
rcol    = $3E
rows    = $3F
j       = $40
part    = $41
tz      = $42
sx      = $43                   ; screen x, 16-bit
bptr    = $45                   ; 16-bit
ncol    = $47
c0      = $48
pp      = $49
lx      = $4A                   ; memory line, 16-bit
dig     = $4C                   ; 3 digits
si      = $4F
fidx    = $50
fbits   = $51
cellr   = $52
cellc   = $53
dx      = $54                   ; 16-bit
gc      = $56
gh      = $57
gl      = $58
bp2     = $59                   ; 16-bit
shown   = $5B                   ; 3 digits currently on the HUD
hy      = $5E
frow    = $5F
bnd     = $60                   ; 10 boundaries
scol    = $6A                   ; 9 colours

.macro  set16 var, value
        lda #<(value)
        sta var
        lda #>(value)
        sta var+1
.endmacro

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

        lda #$33                ; VSCRDEF: TFA 20 (HUD), VSA 300, BFA 0
        jsr cmd
        lda #0
        jsr dat
        lda #TFA
        jsr dat
        lda #>RING
        jsr dat
        lda #<RING
        jsr dat
        lda #0
        jsr dat
        lda #0
        jsr dat
        lda #0
        sta s
        sta s+1
        jsr send_scroll

        jsr gen_bird

        lda #CI_OUTLINE         ; HUD strip
        sta rcol
        lda #0
        sta ry0
        lda #LCD_H - 1
        sta ry1
        set16 lx, 0
        lda #TFA
        sta part
        jsr lrect
        lda #CI_SKY             ; world: sky and ground, two halves of 150 columns
        ldx #0
        ldy #GROUND_Y - 1
        jsr band
        lda #CI_GRASS
        ldx #GROUND_Y
        ldy #GROUND_Y + 3
        jsr band
        lda #CI_GRASS_DK
        ldx #GROUND_Y + 4
        ldy #GROUND_Y + 5
        jsr band
        lda #CI_DIRT
        ldx #GROUND_Y + 6
        ldy #LCD_H - 1
        jsr band
        lda #CI_DIRT_DK
        ldx #GROUND_Y + 20
        ldy #GROUND_Y + 22
        jsr band

; ---- new game: bird hovers until the first flap ----
newgame:
        jsr setup
        lda #0
        sta flap
@wait:  jsr rnd                 ; press timing seeds the random gaps
        lda flap
        beq @wait
        jmp doflap

setup:  lda #BIRD_Y0
        sta yp
        sta oy
        lda #0
        sta yf
        sta vy
        sta vy+1
        sta score
        sta score+1
        lda #NOPIPE
        ldx #NSLOT - 1
:       sta cgap,x
        sta pgap,x
        dex
        bpl :-
        lda #$FF                ; force a full HUD redraw
        sta shown
        sta shown+1
        sta shown+2
        jsr hud_update
        set16 sx, BIRD_X
        jsr to_q
        jsr ph_of
        lda phase
        sta pp
        jmp put_bird

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

        clc                     ; s = (s + STEP) mod 300
        lda s
        adc #STEP
        sta s
        lda s+1
        adc #0
        sta s+1
        beq :+
        lda s
        cmp #<RING
        bcc :+
        sbc #<RING
        sta s
        lda #0
        sta s+1
:       jsr send_scroll

        jsr new_cols
        jsr erase_v
        jsr put_bird
        lda yp
        sta oy
        jsr rnd
        jsr collide
        bcs died
        jsr scorechk
        jmp play

; Game over: the score stays until a press; presses in the first ~1 s are ignored.
; The restart press also counts as the first flap.
died:   jsr show_score
        ldx #8
:       txa
        pha
        jsr delay
        pla
        tax
        dex
        bne :-
        lda #0
        sta flap
@wait:  jsr rnd
        lda flap
        beq @wait
        jsr cleanup
        jsr setup
        jmp doflap

; =========================================================================
physics:
        clc
        lda vy
        adc #<GRAV
        sta vy
        lda vy+1
        adc #>GRAV
        sta vy+1
        bmi @move
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
        cmp #$E0                ; went above the top
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

; C = 1 if the bird box (BIRD_X..+17, yp..yp+17) touches a pipe or the ground
collide:
        lda yp
        cmp #BIRD_MAX
        bcs @yes
        set16 sx, BIRD_X + BIRD_W - 1
        jsr to_q
        jsr ph_of
        lda phase
        cmp #PIPE_W
        bcc @pipe
        set16 sx, BIRD_X
        jsr to_q
        jsr ph_of
        lda phase
        cmp #PIPE_W
        bcs @no
@pipe:  ldx slot
        lda cgap,x
        cmp #NOPIPE
        beq @no
        sta tz
        lda yp
        cmp tz
        bcc @yes
        lda tz
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

; +1 when a pipe's last column passes the bird's left edge; updates the HUD
scorechk:
        set16 sx, BIRD_X
        jsr to_q
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
        lda phase
        sta pp
        jmp hud_update
@save:  lda phase
        sta pp
        rts

; =========================================================================
; The STEP columns that just wrapped to the right edge
new_cols:
        lda #0
        sta j
@col:   lda #<(LCD_W - STEP)
        clc
        adc j
        sta sx
        lda #>(LCD_W - STEP)
        adc #0
        sta sx+1
        jsr to_q
        jsr ph_of
        lda phase
        bne @notnew
        ldx slot                ; a new pipe enters this slot
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
        bcs @skip
        ldx slot
        lda cgap,x
        cmp #NOPIPE
        beq @skip
        sta gt
        lda pgap,x
        sta gp
        cmp gt
        beq @skip               ; same gap as last time: column already right
        jsr pipe_col
        jmp @next
@skip:  jsr delay_col
@next:  inc j
        lda j
        cmp #STEP
        bne @col
        rts

; Pipe column at ring position q, phase 0..29, gap gt, previous gap gp.
; gp = NOPIPE: draw all 200 rows. Otherwise only [min-12, max) and
; [min+GAP, max+GAP+12): above and below those, old and new are identical.
pipe_col:
        lda q
        clc
        adc #TFA
        sta x0
        sta x1
        lda q+1
        adc #0
        sta x0+1
        sta x1+1
        lda #0
        sta y0+1
        sta y1+1

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
        lda #CI_PIPE_EDGE
        sta scol+1
        sta scol+3
        sta scol+5
        sta scol+7
        lda #CI_SKY
        sta scol+4

        lda gp
        cmp #NOPIPE
        bne @two
        lda #0
        sta r0
        lda #GROUND_Y
        sta r1
        jsr setrows
        jsr window
        jsr segs
        jmp flush

@two:   lda gt                  ; range 1: [min - 12, max)
        cmp gp
        bcc :+
        lda gp
:       sec
        sbc #12
        sta r0
        lda gt
        cmp gp
        bcs :+
        lda gp
:       sta r1
        jsr setrows
        jsr window
        jsr segs
        jsr flush
        lda gt                  ; range 2: [min + GAP, max + GAP + 12)
        cmp gp
        bcc :+
        lda gp
:       clc
        adc #GAP
        sta r0
        lda gt
        cmp gp
        bcs :+
        lda gp
:       clc
        adc #GAP + 12
        sta r1
        jsr setrows
        jsr window_y
        jsr segs
        jmp flush

setrows:
        lda r0
        sta y0
        ldx r1
        dex
        stx y1
        rts

; send the 9 segments clipped to rows r0..r1-1
segs:   lda #0
        sta segi
@seg:   ldx segi
        lda bnd,x
        cmp r0
        bcs :+
        lda r0
:       sta tz
        lda bnd+1,x
        cmp r1
        bcc :+
        lda r1
:       sec
        sbc tz
        bcc @next
        beq @next
        sta cnt
        lda scol,x
        jsr emit
@next:  inc segi
        lda segi
        cmp #9
        bne @seg
        rts

body_id:
        .byte CI_SKY, CI_SKY, CI_PIPE_EDGE
        .byte CI_PIPE_LT, CI_PIPE_LT, CI_PIPE_LT, CI_PIPE_LT
        .repeat 15
        .byte CI_PIPE
        .endrepeat
        .byte CI_PIPE_DK, CI_PIPE_DK, CI_PIPE_DK, CI_PIPE_DK, CI_PIPE_DK
        .byte CI_PIPE_EDGE, CI_SKY, CI_SKY
cap_id:
        .byte CI_PIPE_EDGE
        .byte CI_PIPE_LT, CI_PIPE_LT, CI_PIPE_LT, CI_PIPE_LT
        .repeat 18
        .byte CI_PIPE
        .endrepeat
        .byte CI_PIPE_DK, CI_PIPE_DK, CI_PIPE_DK, CI_PIPE_DK, CI_PIPE_DK, CI_PIPE_DK
        .byte CI_PIPE_EDGE

; =========================================================================
; Bird

; old rows the bird left when it moved up or down (cols BIRD_X-STEP .. +17)
erase_v:
        lda yp
        cmp oy
        beq @done
        bcc @up
        lda oy
        sta ry0
        ldx yp
        dex
        stx ry1
        jmp @do
@up:    lda yp
        clc
        adc #BIRD_H
        sta ry0
        lda oy
        clc
        adc #BIRD_H - 1
        sta ry1
@do:    set16 sx, BIRD_X - STEP
        lda #BIRD_W
        sta rw
        lda #CI_SKY
        sta rcol
        jmp srect
@done:  rts

; draw STEP sky columns + the bird at screen BIRD_X-STEP, row yp
put_bird:
        set16 sx, BIRD_X - STEP
        jsr to_q
        lda q                   ; fits before the end of the ring? q + BW2 <= RING
        clc
        adc #BW2
        sta tz
        lda q+1
        adc #0
        cmp #>RING
        bcc @fast
        bne @split
        lda tz
        cmp #<RING + 1
        bcs @split
@fast:  lda q
        clc
        adc #TFA
        sta x0
        lda q+1
        adc #0
        sta x0+1
        lda x0
        clc
        adc #BW2 - 1
        sta x1
        lda x0+1
        adc #0
        sta x1+1
        jsr birdrows
        jsr window
        ldx #DC
        ldy #DC | SDA
        jsr BCODE
        jmp flush
@split: lda #<RING              ; k = RING - q columns before the wrap
        sec
        sbc q
        sta part
        lda q
        clc
        adc #TFA
        sta lx
        lda q+1
        adc #0
        sta lx+1
        lda #0
        sta c0
        lda part
        sta ncol
        jsr slow_part
        set16 lx, TFA
        lda part
        sta c0
        lda #BW2
        sec
        sbc part
        sta ncol
        ; fall through

; columns c0..c0+ncol-1 of BPIX at memory line lx (pixel by pixel)
slow_part:
        lda lx
        sta x0
        clc
        adc ncol
        sta x1
        lda lx+1
        sta x0+1
        adc #0
        sta x1+1
        lda x1
        bne :+
        dec x1+1
:       dec x1
        jsr birdrows
        jsr window
        lda #<BPIX
        clc
        adc c0
        sta bptr
        lda #>BPIX
        adc #0
        sta bptr+1
        lda #BIRD_H
        sta rows
@r:     lda #0
        sta gc
@c:     ldy gc
        lda (bptr),y
        ldx #1
        stx cnt
        jsr emit
        inc gc
        lda gc
        cmp ncol
        bne @c
        lda bptr
        clc
        adc #BW2
        sta bptr
        bcc :+
        inc bptr+1
:       dec rows
        bne @r
        jmp flush

birdrows:
        lda yp
        sta y0
        clc
        adc #BIRD_H - 1
        sta y1
        lda #0
        sta y0+1
        sta y1+1
        rts

; Compile the bird into RAM: for every pixel of the BW2 x 18 picture
; (STEP sky columns, then the sprite), 16 x "stx SPI" (0 bit) / "sty SPI" (1 bit).
gen_bird:
        set16 cp, BCODE
        set16 bp2, BPIX
        set16 bptr, bird16
        lda #BIRD_H
        sta rows
@row:   lda #0
        sta gc
@col:   lda gc
        cmp #STEP
        bcs @spr
        lda #CI_SKY
        jmp @have
@spr:   sec
        sbc #STEP
        tay
        lda (bptr),y            ; colour id * 16
        lsr
        lsr
        lsr
        lsr
@have:  ldy #0
        sta (bp2),y
        inc bp2
        bne :+
        inc bp2+1
:       tax
        lda gcol_hi,x
        sta gh
        lda gcol_lo,x
        sta gl
        ldx #16
@bit:   asl gl
        rol gh                  ; C = next bit, MSB first
        lda #$8E                ; stx abs
        bcc :+
        lda #$8C                ; sty abs
:       jsr put
        lda #<SPI
        jsr put
        lda #>SPI
        jsr put
        dex
        bne @bit
        inc gc
        lda gc
        cmp #BW2
        bne @col
        lda bptr
        clc
        adc #BIRD_W
        sta bptr
        bcc :+
        inc bptr+1
:       dec rows
        bne @row
        lda #$60                ; rts
        ; fall through
put:    ldy #0
        sta (cp),y
        inc cp
        bne :+
        inc cp+1
:       rts

; =========================================================================
; HUD: 3 digits stacked in the fixed strip (x 4-15), blank leading zeros.
hud_update:
        jsr digits
        ldx #0
@d:     lda dig,x
        cmp shown,x
        beq @same
        sta shown,x
        stx si
        lda hud_y,x
        sta hy
        lda dig,x
        jsr hud_digit
        ldx si
@same:  inx
        cpx #3
        bne @d
        rts

hud_y:  .byte 8, 34, 60

; dig[0..2] = hundreds, tens, ones; leading zeros -> 10 (blank)
digits: lda score+1
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
        lda dig
        bne @done
        lda #10
        sta dig
        lda dig+1
        bne @done
        lda #10
        sta dig+1
@done:  rts

; A = digit (10 = blank), drawn at x 4..15, rows hy..hy+19 (4x4 px cells)
hud_digit:
        sta tz
        asl
        asl
        clc
        adc tz
        sta fidx
        set16 x0, 4
        set16 x1, 15
        lda hy
        sta y0
        clc
        adc #19
        sta y1
        lda #0
        sta y0+1
        sta y1+1
        jsr window
        lda #5
        sta cellr
@fr:    lda #4
        sta frow
@row:   ldx fidx
        lda font,x
        sta fbits
        lda #3
        sta cellc
@cell:  lda #4
        sta cnt
        lda fbits
        and #4
        beq :+
        lda #CI_SCORE
        bne :++
:       lda #CI_OUTLINE
:       jsr emit
        asl fbits
        dec cellc
        bne @cell
        dec frow
        bne @row
        inc fidx
        dec cellr
        bne @fr
        jmp flush

; Game over: up to 3 big digits (6 px cells) in the middle of the world
show_score:
        jsr digits
        ldx #0
        lda dig
        cmp #10
        bne @go
        inx
        lda dig+1
        cmp #10
        bne @go
        inx
@go:    stx si
        lda xs_tab,x
        sta dx
        lda #0
        sta dx+1
@dig:   ldx si
        lda dig,x
        jsr big_digit
        lda dx
        clc
        adc #24
        sta dx
        inc si
        lda si
        cmp #3
        bne @dig
        rts

xs_tab: .byte 127, 139, 151

big_digit:
        sta tz
        asl
        asl
        clc
        adc tz
        sta fidx
        lda #CI_SCORE
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
        .byte 0,0,0,0,0         ; 10 = blank

; After game over: pipes (3 slots of 30 lines), the big score and the bird -> sky
cleanup:
        lda #CI_SKY
        sta rcol
        lda #0
        sta ry0
        lda #GROUND_Y - 1
        sta ry1
        lda #PIPE_W
        sta part
        set16 lx, TFA
        jsr lrect
        set16 lx, TFA + PERIOD
        jsr lrect
        set16 lx, TFA + 2 * PERIOD
        jsr lrect
        set16 sx, 127
        lda #66
        sta rw
        lda #SCORE_Y
        sta ry0
        lda #SCORE_Y + 29
        sta ry1
        jsr srect
        set16 sx, BIRD_X - STEP
        lda #BW2
        sta rw
        lda yp
        sta ry0
        clc
        adc #BIRD_H - 1
        sta ry1
        jmp srect

; =========================================================================
; Helpers

; q = (sx - TFA + s) mod 300, for a screen x in the scrolling part
to_q:   lda sx
        sec
        sbc #TFA
        sta q
        lda sx+1
        sbc #0
        sta q+1
        clc
        lda q
        adc s
        sta q
        lda q+1
        adc s+1
        sta q+1
        cmp #>RING
        bcc @ok
        bne @sub
        lda q
        cmp #<RING
        bcc @ok
@sub:   lda q
        sec
        sbc #<RING
        sta q
        lda q+1
        sbc #>RING
        sta q+1
@ok:    rts

; slot = q / 100, phase = q mod 100
ph_of:  lda q
        sta phase
        lda q+1
        sta tz
        ldx #0
@l:     lda tz
        bne @sub
        lda phase
        cmp #PERIOD
        bcc @done
@sub:   lda phase
        sec
        sbc #PERIOD
        sta phase
        lda tz
        sbc #0
        sta tz
        inx
        jmp @l
@done:  stx slot
        rts

; fill a screen rect: x sx..sx+rw-1 (scrolling part, wraps), rows ry0..ry1, colour rcol
srect:  jsr to_q
        lda #<RING
        sec
        sbc q
        sta tz
        lda #>RING
        sbc q+1
        bne @one
        lda tz
        cmp rw
        bcs @one
        sta part
        jsr q_lrect
        lda #0
        sta q
        sta q+1
        lda rw
        sec
        sbc part
        sta part
        jmp q_lrect
@one:   lda rw
        sta part
q_lrect:
        lda q
        clc
        adc #TFA
        sta lx
        lda q+1
        adc #0
        sta lx+1
        ; fall through

; fill memory lines lx..lx+part-1, rows ry0..ry1 with colour rcol
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
@r:     lda part
        sta cnt
        lda rcol
        jsr emit
        dec rows
        bne @r
        jmp flush

; A = colour, X..Y = rows: fill that band across the whole world (2 x 150 lines)
band:   sta rcol
        stx ry0
        sty ry1
        lda #150
        sta part
        set16 lx, TFA
        jsr lrect
        set16 lx, TFA + 150
        jmp lrect

; VSCRSADD = TFA + s
send_scroll:
        lda #$37
        jsr cmd
        lda s
        clc
        adc #TFA
        sta tz
        lda s+1
        adc #0
        jsr dat
        lda tz
        jmp dat

rnd:    lda rng
        asl
        bcc :+
        eor #$1D
:       sta rng
        rts

; about the cost of one pipe column, so frames stay evenly timed
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
