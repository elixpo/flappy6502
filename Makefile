# Assemble asm/*.s into 8 KiB 28C64 images in build/.
#   make            build everything
#   make test       build, then run every image in the simulator
#   ./flash build/ramtest.bin
CC65 ?= $(HOME)/.local/opt/cc65/bin

SOURCES := $(wildcard asm/*.s)
IMAGES  := $(patsubst asm/%.s,build/%.bin,$(SOURCES))

all: $(IMAGES)

build/%.bin: asm/%.s asm/rom.cfg
	@mkdir -p build
	$(CC65)/ca65 -o build/$*.o -l build/$*.lst $<
	$(CC65)/ld65 -C asm/rom.cfg -o $@ build/$*.o

test: all
	uv run python tools/sim.py

clean:
	rm -f build/*.o build/*.lst $(IMAGES)

.PHONY: all test clean
