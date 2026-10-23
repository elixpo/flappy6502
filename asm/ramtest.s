; Stage 3 RAM test for the HY62C SRAM at $0000-$7FFF.
;
; LEDs: wired +5V -> 470R -> LED -> Qx, so an LED is ON when its bit is 0.
;   all 4 LEDs off ............. test running (~4 s)
;   running light QA>QB>QC>QD .. PASS (uses JSR/RTS, so the stack works too)
;   QA+QB on, steady ........... FAIL: address line (open, stuck or shorted A0-A14)
;   QB+QC on, steady ........... FAIL: zero page data ($0000-$00FF)
;   QC+QD on, steady ........... FAIL: main RAM data ($0100-$7FFF)
;   QA+QD on, steady ........... FAIL: stack (PHA/PLA)
;   anything else / frozen ..... CPU crashed

        .setcpu "6502"

LATCH   = $8000
ptr     = $00                   ; 2 bytes, pointer for (ptr),y
xorv    = $02                   ; $00 on pass 1, $FF on pass 2
pat     = $03                   ; running-light bit

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
        lda #$0F                ; all LEDs off = testing
        sta LATCH

; ---- test 0: address lines, absolute addressing only (no RAM variables) ----
; Write a unique value to $0001, $0002, $0004 ... $4000, then 0 to $0000.
; Any open, stuck or shorted address line makes two of these the same byte.
        .repeat 15, k
        lda #(k + 1)
        sta 1 << k
        .endrepeat
        lda #0
        sta $0000
        .repeat 15, k
        lda 1 << k
        cmp #(k + 1)
        jne failA
        .endrepeat
        lda $0000
        jne failA

; ---- test 1: zero page, data = address, then data = ~address ----
        ldx #0
zpw1:   txa
        sta $00,x
        inx
        bne zpw1
zpr1:   txa
        cmp $00,x
        jne failZ
        inx
        bne zpr1
zpw2:   txa
        eor #$FF
        sta $00,x
        inx
        bne zpw2
zpr2:   txa
        eor #$FF
        cmp $00,x
        jne failZ
        inx
        bne zpr2

; ---- test 2: $0100-$7FFF, data = lo ^ hi ^ xorv, two passes ----
        lda #$00
        sta xorv
pass:   ldy #0
        sty ptr
        lda #$01
        sta ptr+1
fill:   tya
        eor ptr+1
        eor xorv
        sta (ptr),y
        iny
        bne fill
        inc ptr+1
        lda ptr+1
        cmp #$80
        bne fill

        lda #$01
        sta ptr+1
check:  tya
        eor ptr+1
        eor xorv
        cmp (ptr),y
        jne failM
        iny
        bne check
        inc ptr+1
        lda ptr+1
        cmp #$80
        bne check

        lda xorv
        bne stack
        lda #$FF
        sta xorv
        bne pass                ; always taken

; ---- test 3: stack ----
stack:  lda #$5A
        pha
        lda #$A5
        pha
        pla
        cmp #$A5
        jne failS
        pla
        cmp #$5A
        jne failS

; ---- PASS: running light, timed by a subroutine ----
        lda #$01
        sta pat
okloop: lda pat
        eor #$0F                ; LED on for the set bit
        sta LATCH
        jsr delay
        asl pat
        lda pat
        cmp #$10
        bne okloop
        lda #$01
        sta pat
        bne okloop              ; always taken

; ~164k cycles = ~0.26 s at 625 kHz
delay:  ldy #$80
        ldx #0
@d:     dex
        bne @d
        dey
        bne @d
        rts

failA:  lda #$0C                ; QA+QB on
        bne show
failZ:  lda #$09                ; QB+QC on
        bne show
failM:  lda #$03                ; QC+QD on
        bne show
failS:  lda #$06                ; QA+QD on
show:   sta LATCH
halt:   jmp halt

irq:
nmi:    rti

        .segment "VECTORS"
        .word nmi, reset, irq
