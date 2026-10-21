#!/usr/bin/env bash
#
# Build the CANHACK_FD firmware without copying files around.
#
# MicroPython lives inside this repo as a git submodule
# (CANPico/firmware/micropython). This script symlinks the overlay files from
# src/ into the MicroPython rp2 port and builds, so edits to src/ take effect
# directly and nothing has to be copied by hand.
#
# Usage:
#   git submodule update --init CANPico/firmware/micropython   # once
#   export PATH=/opt/arm-gnu-toolchain-13.3.rel1-.../bin:$PATH  # the Arm toolchain
#   CANPico/firmware/build.sh                                   # -> fw_canhack_RPI_PICO.uf2
#
# Env overrides:
#   BOARD=RPI_PICO_W            target board (default RPI_PICO)
#   MODULES="CANHACK_BOARD CANHACK_FD"   module markers to touch (default: those two)
#   MPY_DIR=/path/to/micropython         use a MicroPython checkout elsewhere
#   JOBS=8                     parallel build jobs (default: nproc)
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"            # .../CANPico/firmware
SRC="$HERE/src"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
BOARD="${BOARD:-RPI_PICO}"
MODULES="${MODULES:-CANHACK_BOARD CANHACK_FD}"
MPY_DIR="${MPY_DIR:-$HERE/micropython}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
RP2="$MPY_DIR/ports/rp2"

command -v arm-none-eabi-gcc >/dev/null 2>&1 || {
    echo "error: arm-none-eabi-gcc not in PATH -- add the Arm GNU toolchain first." >&2
    exit 1
}

# The host tool mpy-cross is built with the native compiler. Very new host GCCs
# (>= 15) turn new warnings into errors on MicroPython v1.22.2's own sources, so
# relax -Werror for the host build. Harmless for the ARM target build (cmake-driven,
# does not read CFLAGS_EXTRA). Override by exporting CFLAGS_EXTRA yourself.
export CFLAGS_EXTRA="${CFLAGS_EXTRA:--Wno-error}"

if [ ! -d "$RP2" ]; then
    echo "error: MicroPython not found at $MPY_DIR" >&2
    echo "  run:  git submodule update --init CANPico/firmware/micropython" >&2
    echo "  (or set MPY_DIR to an existing v1.22.2 checkout)" >&2
    exit 1
fi

echo ">> MicroPython: $MPY_DIR"
echo ">> fetching port submodules (pico-sdk, tinyusb, ...)"
make -C "$RP2" BOARD="$BOARD" submodules >/dev/null

echo ">> linking overlay from $SRC"
link() { ln -sfn "$1" "$2"; }                    # -n: don't descend into an existing symlinked dir
link "$SRC/CMakeLists.txt"              "$RP2/CMakeLists.txt"
link "$SRC/main.c"                      "$RP2/main.c"
link "$SRC/modrp2.c"                    "$RP2/modrp2.c"
mkdir -p "$RP2/canis"
for f in "$SRC"/canis/*; do link "$f" "$RP2/canis/$(basename "$f")"; done
link "$SRC/tusb_config.h"               "$MPY_DIR/shared/tinyusb/tusb_config.h"
link "$SRC/mp_usbd_descriptor.c"        "$MPY_DIR/shared/tinyusb/mp_usbd_descriptor.c"
link "$SRC/RPI_PICO/mpconfigboard.h"    "$RP2/boards/RPI_PICO/mpconfigboard.h"
link "$SRC/RPI_PICO_W/mpconfigboard.h"  "$RP2/boards/RPI_PICO_W/mpconfigboard.h"

echo ">> enabling modules: $MODULES"
( cd "$RP2" && rm -f CHV_DEFCON30_BADGE CANHACK_BOARD CANPICO_BOARD CANHACK CANHACK_FD MIN_PROTOCOL
  for m in $MODULES; do touch "$m"; done )

# Stamp the canhack_fd git hash (reported by ch.build_info()); +dirty if src/ is modified.
hash="$(git -C "$REPO" rev-parse --short HEAD)"
git -C "$REPO" diff --quiet -- "$SRC" 2>/dev/null || hash="$hash+dirty"
export CANHACK_FD_GITHASH="$hash"
echo ">> CANHACK_FD_GITHASH=$CANHACK_FD_GITHASH"

echo ">> building (clean configure so the build timestamp refreshes)"
rm -rf "$RP2/build-$BOARD"
make -C "$RP2" BOARD="$BOARD" -j"$JOBS"

out="$HERE/fw_canhack_${BOARD}.uf2"
cp "$RP2/build-$BOARD/firmware.uf2" "$out"
echo ">> done: $out"
