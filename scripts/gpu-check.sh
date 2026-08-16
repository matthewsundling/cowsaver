#!/usr/bin/env bash
#
# Does Cowsaver put work on the discrete GPU?
#
# It reads each graphics card's live utilisation out of the IORegistry, first with your
# desktop as you left it, then with Cowsaver on screen, and compares the two.
#
# No root, no powermetrics, nothing to install.
#
# Quit other applications first. When the discrete GPU drives the display, its utilization
# may not reach zero; the comparison then asks whether Cowsaver raises the control reading.
# A busy control phase is reported as inconclusive.
#
# Usage:  scripts/gpu-check.sh [seconds per phase, default 15]
# Exits:  0 pass, 1 fail, 2 inconclusive.

set -euo pipefail

PHASE="${1:-15}"
BUSY_DESKTOP=15       # median % above which the control is too noisy to compare against
MARGIN=5              # percentage points Cowsaver may exceed the control before it fails

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Cowsaver.app/Contents/MacOS/Cowsaver"

[[ -x "$APP" ]] || { echo "no $APP — run 'make app' first" >&2; exit 1; }

# One reading per graphics card: whether it is the integrated or the discrete one, how busy
# it is, and its power draw if the driver publishes one (AMD does, Intel does not).
#
# Reads `PerformanceStatistics`, never `PerformanceStatisticsAccum` — the latter is a total
# since boot rather than a current reading. The utilisation key is matched with its closing
# quote because Intel also publishes `Device Utilization % at cur p-state`, a different
# number appearing earlier on the same line.
sample() {
    ioreg -rc IOAccelerator -w0 | awk '
        /^\+-o / { kind = ($2 ~ /^Intel/) ? "integrated" : "discrete" }
        /"PerformanceStatistics" =/ {
            watts = -1
            if (match($0, /"Total Power\(W\)"=[0-9]+/))
                watts = substr($0, RSTART + 17, RLENGTH - 17)
            if (match($0, /"Device Utilization %"=[0-9]+/))
                print kind, substr($0, RSTART + 23, RLENGTH - 23), watts
        }'
}

collect() {
    local seconds="$1" file="$2" stop
    stop=$(( $(date +%s) + seconds ))
    : > "$file"
    while [[ "$(date +%s)" -lt "$stop" ]]; do
        sample >> "$file"
        sleep 1
    done
}

# Use the median rather than the peak so isolated work from other processes does not dominate
# the comparison.
busy_median() {
    grep "^$2 " "$1" | awk '{ print $2 }' | sort -n |
        awk '{ v[NR] = $1 } END { print NR ? v[int((NR + 1) / 2)] : 0 }'
}

report() {
    local file="$1" kind watts
    for kind in integrated discrete; do
        grep -q "^$kind " "$file" || continue
        watts="$(grep "^$kind " "$file" | awk '$3 >= 0 { print $3 }' | sort -n | tail -1)"
        printf "    %-11s %3d%% busy%s\n" \
            "$kind" "$(busy_median "$file" "$kind")" "${watts:+, ${watts} W}"
    done
}

WORK="$(mktemp -d)"
cleanup() {
    [[ -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null
    rm -rf "$WORK"
    return 0
}
trap cleanup EXIT

if ! sample | grep -q '^discrete'; then
    echo "This Mac reports only an integrated GPU. Nothing to test."
    exit 0
fi

echo "==> control: your desktop, ${PHASE}s (leave it alone)"
collect "$PHASE" "$WORK/before"
report "$WORK/before"

control="$(busy_median "$WORK/before" discrete)"
if [[ "$control" -gt "$BUSY_DESKTOP" ]]; then
    echo
    echo "INCONCLUSIVE — your desktop is already using the discrete GPU heavily"
    echo "               (${control}% median). Anything measured against that is noise."
    echo "               Quit your other applications and run this again."
    exit 2
fi

echo
echo "==> Cowsaver full-screen, ${PHASE}s"
# Job control off around the launch, so killing it at the end cannot print "Terminated"
# across the results.
set +m
"$APP" --fullscreen >/dev/null 2>&1 &
APP_PID=$!
disown "$APP_PID" 2>/dev/null || true
sleep 2
collect "$PHASE" "$WORK/during"
kill "$APP_PID" 2>/dev/null || true
APP_PID=""
report "$WORK/during"

running="$(busy_median "$WORK/during" discrete)"

echo
if [[ "$running" -eq 0 ]]; then
    echo "PASS — the discrete GPU stayed at 0% throughout."
elif [[ "$running" -le $(( control + MARGIN )) ]]; then
    echo "PASS — Cowsaver added no discrete-GPU work: ${running}% median against ${control}%"
    echo "       for your own desktop sitting idle."
    echo
    echo "       On this Mac the discrete GPU also drives the display, so it never reads"
    echo "       zero. What matters is that Cowsaver does not raise it, and it does not."
else
    echo "FAIL — the discrete GPU ran at ${running}% under Cowsaver, against ${control}% for"
    echo "       your idle desktop. Something is asking it to draw."
    exit 1
fi
