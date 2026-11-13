#!/bin/bash
# lll-firmware.sh - build and flash the Nitrooxyde "Mellow LLL Plus Canonical" Klipper firmware
# onto Mellow FLY LLL Buffer Plus units, WITHOUT modifying ~/klipper.
# Written 2026-11-12 for Shane's StealthChanger (Klipper v0.13.0-827, CM5 host).
#
# Why a separate build copy: the buffer firmware needs one extra line in Klipper's src/Makefile.
# Editing ~/klipper makes that repo "modified", and Moonraker then refuses to update Klipper
# ("Update aborted, repo has been modified"). This script keeps a private copy, ~/klipper-lll,
# pinned to the exact commit ~/klipper is on, and builds the buffers from it. The firmware
# reports the same version string as the host and the other boards (no "-dirty").
#
# Usage (on the Pi):
#   ~/lll-firmware.sh list               buffers seen on USB, with their serials
#   ~/lll-firmware.sh katapult           FIRST TIME, one board at a time, board in DFU mode:
#                                        backs up the stock firmware, installs Katapult
#   ~/lll-firmware.sh flash SERIAL...    build and flash the buffer firmware over USB (no buttons)
#   ~/lll-firmware.sh build              build only
#
# After every Klipper update (after UKAM has flashed the other boards), run "flash" again with
# all buffer serials. Klipper is stopped while flashing and started again afterwards.

set -euo pipefail

LLL_SRC="$HOME/lll-firmware"      # git clone of github.com/Nitrooxyde/Mellow-LLL-Plus-Canonical
KLIPPER="$HOME/klipper"           # the Klipper that klippy runs from (Moonraker / UKAM manage it)
KATAPULT="$HOME/katapult"         # github.com/Arksine/katapult (flashtool + bootloader source)
BUILD="$HOME/klipper-lll"         # private build copy of ~/klipper (created on first run)
WORK="$HOME/lll-build"            # Katapult build output and stock-firmware backups
PY="$HOME/klippy-env/bin/python"
FT="$KATAPULT/scripts/flashtool.py"
BYID=/dev/serial/by-id
KPRE=usb-Klipper_stm32f072xb_
BPRE=usb-katapult_stm32f072xb_

die() { echo "ERROR: $*" >&2; exit 1; }
need() { [ -e "$1" ] || die "$2"; }

check_sources() {
  need "$LLL_SRC/src/buffer.c" "firmware source missing: git clone https://github.com/Nitrooxyde/Mellow-LLL-Plus-Canonical.git ~/lll-firmware"
  need "$KLIPPER/.git" "$KLIPPER is not a git checkout"
  need "$FT" "Katapult missing: git clone https://github.com/Arksine/katapult ~/katapult"
  need "$PY" "$PY not found"
  command -v arm-none-eabi-gcc >/dev/null || die "ARM compiler missing: sudo apt install gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi"
}

wait_for() {  # wait_for <path> <seconds>
  for _ in $(seq 1 "$2"); do [ -e "$1" ] && return 0; sleep 1; done
  return 1
}

cmd_list() {
  local found=0 f
  for f in "$BYID"/${KPRE}*-if00 "$BYID"/${BPRE}*-if00; do
    [ -e "$f" ] || continue
    found=1
    f=${f##*/}
    case "$f" in
      ${KPRE}*) echo "${f#$KPRE}" | sed 's/-if00$/   running Klipper/' ;;
      ${BPRE}*) echo "${f#$BPRE}" | sed 's/-if00$/   in Katapult (ready to flash)/' ;;
    esac
  done
  [ "$found" = 1 ] || echo "No LLL buffers (STM32F072) on USB."
}

build_klipper() {
  check_sources
  local head ver
  head=$(git -C "$KLIPPER" rev-parse HEAD)
  if [ ! -d "$BUILD/.git" ]; then
    echo "Creating private build copy $BUILD ..."
    git clone -q "$KLIPPER" "$BUILD"
  fi
  # Return the copy to ~/klipper's exact commit (this also undoes last run's Makefile line).
  git -C "$BUILD" update-index --no-assume-unchanged src/Makefile 2>/dev/null || true
  git -C "$BUILD" fetch -q --tags "$KLIPPER" HEAD
  git -C "$BUILD" checkout -q -f --detach FETCH_HEAD
  [ "$(git -C "$BUILD" rev-parse HEAD)" = "$head" ] || die "build copy is not on ~/klipper's commit"

  # The two additions the firmware README asks for, made in the copy only.
  cp "$LLL_SRC/src/buffer.c" "$BUILD/src/buffer.c"
  grep -q 'buffer\.c' "$BUILD/src/Makefile" || echo 'src-$(CONFIG_MACH_STM32F072) += buffer.c' >> "$BUILD/src/Makefile"
  # Keeps the version string identical to the host's (git would otherwise add "-dirty").
  git -C "$BUILD" update-index --assume-unchanged src/Makefile

  # Build settings shipped with the firmware: STM32F072, 8 MHz crystal, USB PA11/PA12, 8KiB Katapult.
  cp "$LLL_SRC/build/klipper.config" "$BUILD/.config"
  make -C "$BUILD" olddefconfig >/dev/null
  grep -q '^CONFIG_MCU="stm32f072xb"$' "$BUILD/.config" || die "build config is not for the STM32F072"
  grep -q '^CONFIG_FLASH_APPLICATION_ADDRESS=0x8002000$' "$BUILD/.config" || die "build config is not 8KiB bootloader"

  echo "Building buffer firmware from Klipper $(git -C "$BUILD" describe --always --tags --long --dirty) ..."
  make -C "$BUILD" clean >/dev/null
  if ! make -C "$BUILD" -j"$(nproc)" >"$BUILD/lll-build.log" 2>&1; then
    tail -20 "$BUILD/lll-build.log"
    die "build failed (full log: $BUILD/lll-build.log)"
  fi
  grep -q 'lll_state' "$BUILD/out/klipper.dict" || die "firmware built without the buffer task (buffer.c not compiled)"
  ver=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$BUILD/out/klipper.dict")
  case "$ver" in *dirty*) echo "WARNING: firmware version is '$ver' (expected no -dirty)";; esac

  # Host side from the same lll-firmware checkout. An untracked file: Klipper updates keep it.
  cp "$LLL_SRC/klippy/extras/lll_buffer.py" "$KLIPPER/klippy/extras/lll_buffer.py"
  echo "OK: $BUILD/out/klipper.bin ($(stat -c %s "$BUILD/out/klipper.bin") bytes, $ver); lll_buffer.py installed"
}

flash_one() {
  local s="$1"
  local k="$BYID/${KPRE}${s}-if00" b="$BYID/${BPRE}${s}-if00"
  echo "=== Buffer $s ==="
  if [ -e "$k" ]; then
    "$PY" "$FT" -r -d "$k" >/dev/null 2>&1 || true
    wait_for "$b" 15 || die "$s did not switch to Katapult"
  fi
  [ -e "$b" ] || die "no buffer with serial $s on USB (run: $0 list)"
  "$PY" "$FT" -d "$b" -f "$BUILD/out/klipper.bin"
  wait_for "$k" 20 || die "$s did not come back as Klipper after flashing"
  echo "OK: $s is running the buffer firmware"
}

cmd_flash() {
  [ $# -gt 0 ] || die "give the buffer serials, e.g.: $0 flash 3C003A000957465331323720   (see: $0 list)"
  build_klipper
  echo "Stopping Klipper while flashing ..."
  sudo systemctl stop klipper
  trap 'echo "Starting Klipper ..."; sudo systemctl start klipper' EXIT
  local s
  for s in "$@"; do flash_one "$s"; done
}

build_katapult() {
  local cfg="$WORK/katapult.config" out="$WORK/katapult-out/"
  mkdir -p "$WORK"
  # Katapult for the LLL Plus: STM32F072, 8 MHz crystal, USB PA11/PA12, app at 8KiB,
  # double-click-reset entry OFF (the firmware README says it stops the board enumerating).
  printf '%s\n' \
    'CONFIG_LOW_LEVEL_OPTIONS=y' 'CONFIG_MACH_STM32=y' 'CONFIG_MACH_STM32F072=y' \
    'CONFIG_STM32_CLOCK_REF_8M=y' 'CONFIG_STM32_USB_PA11_PA12=y' 'CONFIG_STM32_APP_START_2000=y' \
    '# CONFIG_ENABLE_DOUBLE_RESET is not set' > "$cfg"
  make -C "$KATAPULT" KCONFIG_CONFIG="$cfg" olddefconfig >/dev/null
  grep -q '^CONFIG_MCU="stm32f072xb"$' "$cfg" || die "Katapult config is not for the STM32F072"
  grep -q '^CONFIG_LAUNCH_APP_ADDRESS=0x8002000$' "$cfg" || die "Katapult app address is not 0x8002000"
  grep -q '^CONFIG_STM32_USB_PA11_PA12=y$' "$cfg" || die "Katapult is not set to USB PA11/PA12"
  grep -q '^# CONFIG_ENABLE_DOUBLE_RESET is not set$' "$cfg" || die "Katapult double-reset entry is on"
  make -C "$KATAPULT" KCONFIG_CONFIG="$cfg" OUT="$out" clean >/dev/null
  make -C "$KATAPULT" KCONFIG_CONFIG="$cfg" OUT="$out" -j"$(nproc)" >"$WORK/katapult-build.log" 2>&1 \
    || { tail -20 "$WORK/katapult-build.log"; die "Katapult build failed"; }
  echo "Katapult built: ${out}katapult.bin ($(stat -c %s "${out}katapult.bin") bytes)"
}

cmd_katapult() {
  check_sources
  command -v dfu-util >/dev/null || die "dfu-util missing: sudo apt install dfu-util"
  local dfu n before tag
  dfu=$(sudo dfu-util -l 2>/dev/null | grep 'Found DFU: \[0483:df11\]' | grep 'alt=0' || true)
  n=$(printf '%s' "$dfu" | grep -c . || true)
  [ "$n" -eq 1 ] || die "need exactly one STM32 in DFU mode, found $n. On ONE buffer: hold BOOT, tap RESET, release BOOT."
  printf '%s' "$dfu" | grep -q '0x08000000/064\*0002Kg' \
    || die "the DFU device is not a 128K STM32F0 (LLL Plus). It reports: $dfu"

  build_katapult

  tag=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$WORK/backups"
  echo "Backing up this buffer's stock firmware to $WORK/backups/lll-$tag-*.bin ..."
  sudo dfu-util -a 0 -d 0483:df11 -U "$WORK/backups/lll-$tag-flash.bin" -s 0x08000000:0x20000
  sudo dfu-util -a 1 -d 0483:df11 -U "$WORK/backups/lll-$tag-optionbytes.bin"
  sudo chown "$(id -u):$(id -g)" "$WORK/backups/lll-$tag-"*.bin

  before=$(ls "$BYID" 2>/dev/null | grep "^${BPRE}" || true)
  echo "Installing Katapult (erases the whole chip) ..."
  sudo dfu-util -a 0 -d 0483:df11 -D "${WORK}/katapult-out/katapult.bin" -s 0x08000000:force:mass-erase:leave || true

  local new=""
  for _ in $(seq 1 15); do
    new=$(ls "$BYID" 2>/dev/null | grep "^${BPRE}" | grep -vxF -e "$before" -e '' || true)
    [ -n "$new" ] && break
    sleep 1
  done
  if [ -z "$new" ]; then
    echo "Katapult was written. The board did not show up yet: unplug and replug its USB, then run: $0 list"
    exit 0
  fi
  new=${new#$BPRE}; new=${new%-if00}
  echo "OK: Katapult installed. Serial: $new"
  echo "Next (24 V must be on the buffer's VIN):  $0 flash $new"
}

case "${1:-}" in
  list)     cmd_list ;;
  build)    build_klipper ;;
  flash)    shift; cmd_flash "$@" ;;
  katapult) cmd_katapult ;;
  *) sed -n '2,21p' "$0"; exit 1 ;;
esac
