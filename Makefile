# Assemble asm/*.s into 8 KiB 28C64 images in build/.
#   make            build everything
#   make test       build, then run every image in the simulator
#   ./flash build/ramtest.bin
CC65 ?= $(HOME)/.local/opt/cc65/bin

SOURCES := $(wildcard asm/*.s)
IMAGES  := $(patsubst asm/%.s,build/%.bin,$(SOURCES))

all: $(IMAGES)

build/%.bin: asm/%.s asm/rom.cfg $(wildcard asm/*.inc) $(SOURCES)
	@mkdir -p build
	$(CC65)/ca65 -I asm -o build/$*.o -l build/$*.lst $<
	$(CC65)/ld65 -C asm/rom.cfg -o $@ build/$*.o

# flappy512 links into $FE00-$FFFF (rom512.cfg): ld65 fails if code + vectors > 512 bytes
build/flappy512.bin: asm/flappy512.s asm/rom512.cfg
	@mkdir -p build
	$(CC65)/ca65 -o build/flappy512.o -l build/flappy512.lst $<
	$(CC65)/ld65 -C asm/rom512.cfg -m build/flappy512.map -o $@ build/flappy512.o
	@python3 -c "import sys; d=open('$@','rb').read()[0x1E00:0x1FFA]; \
	print('flappy512:', len(d.rstrip(bytes([255]))) + 6, 'of 512 bytes (code + vectors)')"

# flappy1k links into $FC00-$FFFF (rom1k.cfg): ld65 fails if code + vectors > 1024 bytes
build/flappy1k.bin: asm/flappy1k.s asm/rom1k.cfg
	@mkdir -p build
	$(CC65)/ca65 -o build/flappy1k.o -l build/flappy1k.lst $<
	$(CC65)/ld65 -C asm/rom1k.cfg -m build/flappy1k.map -o $@ build/flappy1k.o
	@python3 -c "import sys; d=open('$@','rb').read()[0x1C00:0x1FFA]; \
	print('flappy1k:', len(d.rstrip(bytes([255]))) + 6, 'of 1024 bytes (code + vectors)')"

test: all
	uv run python tools/sim.py
	uv run python tools/sim512.py

clean:
	rm -f build/*.o build/*.lst $(IMAGES)

.PHONY: all test clean
