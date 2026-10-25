; SCL circuit probe: writes to $A000 forever (one write every 4 cycles), so every
; signal in the stage-7 SCL chain toggles at a fixed rate and a meter reads steady
; averages. The LCD gets garbage; ignore the screen.

        .setcpu "6502"
        .segment "CODE"

reset:  sei
        cld
        ldx #$FF
        txs
        lda #$05
loop:   .repeat 32
        sta $A000
        .endrepeat
        jmp loop

nmi:
irq:    rti

        .segment "VECTORS"
        .word nmi, reset, irq
