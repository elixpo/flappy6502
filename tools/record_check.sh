#!/usr/bin/env bash
# Record evidence in one command (run it with the EEPROM in the programmer):
#   1. build flappy1k from source and print its size (the build fails above 1,024 bytes)
#   2. read the whole EEPROM back and compare it with that build, byte for byte
#   3. show that everything on the chip outside the 1,024 bytes is empty ($FF)
#     tools/record_check.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== 1. build from source =="
rm -f build/flappy1k.bin
make --no-print-directory build/flappy1k.bin | tail -1
echo "build     sha256: $(sha256sum build/flappy1k.bin | cut -d' ' -f1)"
echo "published sha256: $(sha256sum roms/flappy1k.bin | cut -d' ' -f1)   (roms/flappy1k.bin on GitHub)"

echo
echo "== 2. read the EEPROM back =="
./flash dump build/chip.bin
echo "chip      sha256: $(sha256sum build/chip.bin | cut -d' ' -f1)"

echo
echo "== 3. what is on the chip =="
python3 - <<'EOF'
chip = open("build/chip.bin", "rb").read()
build = open("build/flappy1k.bin", "rb").read()
prog, rest = chip[0x1C00:], chip[:0x1C00]
same = chip == build
empty = all(b == 0xFF for b in rest)
print(f"chip = source build, byte for byte : {'YES' if same else 'NO'}")
print(f"game ($FC00-$FFFF)                 : {len(prog)} bytes")
print(f"rest of chip ($E000-$FBFF)         : {len(rest)} bytes, all empty ($FF): {'YES' if empty else 'NO'}")
print()
print("RESULT:", "the chip holds only the 1,024-byte game, built from the published source"
      if same and empty else "MISMATCH")
EOF
