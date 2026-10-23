; Stage 4: ST7789P3 bring-up, landscape 320x240.
;
; LCD RST is tied to +5V (the module loads the CPU /RES line too much); lcd_init
; starts with a software reset (SWRESET) instead.
;
; What you should see at 1.25 MHz:
;   ~0.5 s    random noise = display on, init worked
;   ~13 s     black wipes the screen
;   ~3 s      five 48x48 squares across the middle, left to right:
;             RED  GREEN  BLUE  WHITE  YELLOW
;   then      the CPU halts; the picture stays.
;
; Colours wrong? white/black swapped -> INVON $21 to INVOFF $20 in lcd.inc;
; red/blue swapped -> MADCTL $60 to $68. Upside down -> MADCTL $A0.

        .setcpu "6502"
        .segment "CODE"
        .include "lcd.inc"
        .include "gfx.inc"

reset:  sei
        cld
        ldx #$FF
        txs
        jsr lcd_init

        fill_rect 0, 0, LCD_W, LCD_H, C_BLACK

        fill_rect   8, 96, 48, 48, C_RED
        fill_rect  72, 96, 48, 48, C_GREEN
        fill_rect 136, 96, 48, 48, C_BLUE
        fill_rect 200, 96, 48, 48, C_WHITE
        fill_rect 264, 96, 48, 48, C_YELLOW

halt:   jmp halt

irq:
nmi:    rti

        .segment "VECTORS"
        .word nmi, reset, irq
