; Flappy Bird v2 for the PROVEN stage-4 wiring: LCD SCL from the LCD latch pin 13
; (no SCL gate chip). Same game as flappy.s (live score strip, pipes every 100 px),
; with SCL toggled in software, so it is slower than the auto-clock version.
BITBANG = 1
        .include "flappy.s"
