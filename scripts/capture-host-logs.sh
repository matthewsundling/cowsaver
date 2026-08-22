#!/usr/bin/env bash
#
# Collect host-behavior diagnostics into one timestamped folder. It includes sw_vers,
# `make doctor`, broad unified-log history for the screensaver host and System Settings,
# and separately filtered Cowsaver and sheet lines. Run it after reproducing a problem.
#
# Usage: scripts/capture-host-logs.sh [window]   (default: 6h; e.g. 30m, 2h, 1d)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WINDOW="${1:-6h}"
DIAGNOSTICS_ROOT="${COWSAVER_DIAGNOSTICS_ROOT:-$HOME/cowsaver-diagnostics}"
OUT="$DIAGNOSTICS_ROOT/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

echo "==> Privacy notice"
echo "host-full.log contains broad screensaver-host and System Settings history."
echo "It may include paths, account context, settings activity, or unrelated content."
echo "Review every file before sharing; filtered files can still contain personal paths or context."

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
echo "<private> placeholders: $(count '<private>')"
echo "This count does not prove any file is safe to share."
echo
echo "Everything is in $OUT"
echo "Normally review and transfer only: doctor.txt, sw_vers.txt, cowsaver.log, and sheet.log."
echo "Do not share host-full.log unless a maintainer specifically requests it and you have reviewed and redacted it as needed."
echo "After reviewing those four files, archive only them with:"
echo "  tar -czf \"$OUT.tgz\" -C \"$OUT\" doctor.txt sw_vers.txt cowsaver.log sheet.log"
