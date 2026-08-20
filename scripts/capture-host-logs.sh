#!/usr/bin/env bash
#
# Collect everything a host-behavior report needs into one timestamped folder:
# sw_vers, `make doctor`, and the unified-log history for the screensaver host and
# System Settings, with Cowsaver's own lines and the sheet plumbing filtered out
# separately. Run it after reproducing a problem; the summary at the end says whether
# the capture actually caught anything.
#
# Usage: scripts/capture-host-logs.sh [window]   (default: 6h; e.g. 30m, 2h, 1d)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WINDOW="${1:-6h}"
OUT="$HOME/cowsaver-diagnostics/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

sw_vers > "$OUT/sw_vers.txt"
make -C "$ROOT" doctor > "$OUT/doctor.txt" 2>&1 || true

echo "==> reading the last ${WINDOW} of host logs (this can take a few minutes)"
log show --last "$WINDOW" --info --debug --style compact \
    --predicate 'process == "legacyScreenSaver" OR process == "System Settings" OR subsystem == "com.matthewsundling.cowsaver"' \
    > "$OUT/host-full.log"

grep -i 'cowsaver' "$OUT/host-full.log" > "$OUT/cowsaver.log" || true
grep -iE 'configure|sheet' "$OUT/host-full.log" > "$OUT/sheet.log" || true

count() { grep -ci "$1" "$OUT/host-full.log" || true; }

echo "==> summary"
echo "host-full.log lines:    $(wc -l < "$OUT/host-full.log" | tr -d ' ')"
echo "cowsaver lines:         $(count 'cowsaver')"
echo "configure/sheet lines:  $(grep -icE 'configure|sheet' "$OUT/host-full.log" || true)"
echo "redacted <private>:     $(count '<private>')"
echo
echo "Everything is in $OUT"
echo "To compress for transfer:"
echo "  tar -czf \"$OUT.tgz\" -C \"$(dirname "$OUT")\" \"$(basename "$OUT")\""
