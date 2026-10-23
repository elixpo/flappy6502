; RAM soak test: repeats forever with a new pseudo-random pattern each pass.
;
; LEDs: wired +5V -> 470R -> LED -> Qx, so an LED is ON when its bit is 0.
;   binary counter on QA-QD, +1 per pass (~5 s each) ... all good so far
;   all 4 LEDs flashing together ........................ FAIL (wrong byte read back)
;   counter stops / random ............................... CPU crashed
;
; Each pass: fill $0010-$00FF and $0200-$7FFF from a 16-bit LFSR seeded by the
; pass number, read it all back, then call a routine that was copied into RAM
; at $0180 (proves code can run from SRAM). $00-$0F = variables, $0100-$01FF =
; stack page (the RAM routine sits low in it, the stack stays at the top).

        .setcpu "6502"

LATCH   = $8000
RAMCODE = $0180

ptr     = $00                   ; 2 bytes
lfsr    = $02                   ; 2 bytes
passes  = $04

        .segment "CODE"

reset:  sei
        cld
        ldx #$FF
        txs
        lda #$0F                ; all LEDs off
        sta LATCH
        lda #0
        sta passes

        ldx #(ramend - ramsrc - 1)
copy:   lda ramsrc,x
        sta RAMCODE,x
        dex
        bpl copy

pass:   jsr seed
        ldx #$10                ; zero page above the variables
zfill:  jsr step
        sta $00,x
        inx
        bne zfill
        lda #$02
        sta ptr+1
        ldy #0
        sty ptr
mfill:  jsr step
        sta (ptr),y
        iny
        bne mfill
        inc ptr+1
        bpl mfill               ; stop at $80

        jsr seed
        ldx #$10
zchk:   jsr step
        cmp $00,x
        bne fail
        inx
        bne zchk
        lda #$02
        sta ptr+1
        ldy #0
mchk:   jsr step
        cmp (ptr),y
        bne fail
        iny
        bne mchk
        inc ptr+1
        bpl mchk

        jsr RAMCODE             ; count the pass and show it, running from RAM
        jmp pass

; lfsr = $ACE1 ^ (passes * $0101), forced non-zero
seed:   lda passes
        eor #$E1
        ora #$01
        sta lfsr
        lda passes
        eor #$AC
        sta lfsr+1
        rts

; 16-bit Galois LFSR (taps $B400); returns the new low byte in A. Keeps X, Y.
step:   lsr lfsr+1
        ror lfsr
        bcc :+
        lda lfsr+1
        eor #$B4
        sta lfsr+1
:       lda lfsr
        rts

fail:   lda #$00                ; all LEDs on
        sta LATCH
        jsr delay
        lda #$0F                ; all LEDs off
        sta LATCH
        jsr delay
        jmp fail

; ~0.13 s at 625 kHz
delay:  ldy #$40
        ldx #0
@d:     dex
        bne @d
        dey
        bne @d
        rts

; Copied to RAMCODE and run from there.
ramsrc: inc passes
        lda passes
        eor #$0F                ; LED on = bit set in the pass count
        sta LATCH
        rts
ramend:

irq:
nmi:    rti

        .segment "VECTORS"
        .word nmi, reset, irq
