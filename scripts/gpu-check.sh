#!/usr/bin/env bash
#
# Does Cowsaver put work on the discrete GPU?
#
# It reads each graphics accelerator's live utilisation out of the IORegistry, first with
# your desktop as you left it, then with Cowsaver on screen, and compares the two. Apple/AGX
# accelerators use unified memory and do not have a discrete GPU to compare.
#
# No root, no powermetrics, nothing to install.
#
# Quit other applications first. When the discrete GPU drives the display, its utilization
# may not reach zero; the comparison then asks whether Cowsaver raises the control reading.
# A busy control phase is reported as inconclusive.
#
# Usage:  scripts/gpu-check.sh [seconds per phase, default 15]
# Exits:  0 pass or not applicable, 1 fail, 2 inconclusive.

set -euo pipefail

PHASE="${1:-15}"
BUSY_DESKTOP=15       # median % above which the control is too noisy to compare against
MARGIN=5              # percentage points Cowsaver may exceed the control before it fails

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${COWSAVER_GPU_APP:-$ROOT/build/Cowsaver.app/Contents/MacOS/Cowsaver}"
IOREG_COMMAND="${COWSAVER_GPU_IOREG_COMMAND:-ioreg}"
SAMPLE_COUNT="${COWSAVER_GPU_SAMPLE_COUNT:-}"
APP_SETTLE_SECONDS="${COWSAVER_GPU_APP_SETTLE_SECONDS:-2}"

read_registry() {
    "$IOREG_COMMAND" -rc IOAccelerator -w0
}

# The same parser produces either a de-duplicated inventory or current utilization readings.
# Reads `PerformanceStatistics`, never `PerformanceStatisticsAccum` — the latter is a total
# since boot rather than a current reading. The utilisation key is matched with its closing
# quote because Intel also publishes `Device Utilization % at cur p-state`, a different
# number appearing earlier on the same line.
parse_registry() {
    local mode="$1"
    awk -v mode="$mode" '
        function classify(accelerator, lowered) {
            lowered = tolower(accelerator)
            if (lowered ~ /apple/ || lowered ~ /agx/)
                return "unified"
            if (lowered ~ /intel/)
                return "integrated"
            if (lowered ~ /amd/ || lowered ~ /ati/ || lowered ~ /radeon/ || lowered ~ /nvidia/)
                return "discrete"
            return "unknown"
        }

        /^\+-o / {
            name = $2
            kind = classify(name)
            if (mode == "inventory" && !seen[kind SUBSEP name]++)
                print kind, name
            next
        }

        mode == "sample" && /"PerformanceStatistics" =/ {
            watts = -1
            if (match($0, /"Total Power\(W\)"=[0-9]+/))
                watts = substr($0, RSTART + 17, RLENGTH - 17)
            if (match($0, /"Device Utilization %"=[0-9]+/))
                print kind, substr($0, RSTART + 23, RLENGTH - 23), watts
        }
    '
}

sample() {
    read_registry | parse_registry sample
}

collect() {
    local seconds="$1" file="$2" stop remaining
    : > "$file"

    # Deterministic tests request a fixed number of samples and skip wall-clock sleeps.
    if [[ -n "$SAMPLE_COUNT" ]]; then
        remaining="$SAMPLE_COUNT"
        while [[ "$remaining" -gt 0 ]]; do
            sample >> "$file" || return 1
            remaining=$(( remaining - 1 ))
        done
        return 0
    fi

    stop=$(( $(date +%s) + seconds ))
    while [[ "$(date +%s)" -lt "$stop" ]]; do
        sample >> "$file" || return 1
        sleep 1
    done
}

# Use the median rather than the peak so isolated work from other processes does not dominate
# the comparison. No readings is an error, not a zero-percent result.
busy_median() {
    grep "^$2 " "$1" | awk '{ print $2 }' | sort -n |
        awk '{ v[NR] = $1 } END { if (!NR) exit 1; print v[int((NR + 1) / 2)] }'
}

report() {
    local file="$1" kind watts median
    for kind in unified integrated discrete unknown; do
        grep -q "^$kind " "$file" || continue
        median="$(busy_median "$file" "$kind")"
        watts="$(grep "^$kind " "$file" | awk '$3 >= 0 { print $3 }' | sort -n | tail -1)"
        printf "    %-11s %3d%% busy%s\n" \
            "$kind" "$median" "${watts:+, ${watts} W}"
    done
}

inconclusive_readings() {
    echo
    echo "INCONCLUSIVE — $1"
    exit 2
}

WORK="$(mktemp -d)"
cleanup() {
    [[ -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null
    rm -rf "$WORK"
    return 0
}
trap cleanup EXIT

if ! read_registry > "$WORK/inventory-raw"; then
    inconclusive_readings "the IORegistry GPU inventory could not be read."
fi
parse_registry inventory < "$WORK/inventory-raw" > "$WORK/inventory"

if [[ ! -s "$WORK/inventory" ]]; then
    inconclusive_readings "no GPU accelerator nodes were found in the IORegistry data."
fi

echo "==> GPU inventory"
awk '{ printf "    %-11s %s\n", $1, $2 }' "$WORK/inventory"

has_discrete=false
has_unified=false
has_integrated=false
has_unknown=false
grep -q '^discrete ' "$WORK/inventory" && has_discrete=true
grep -q '^unified ' "$WORK/inventory" && has_unified=true
grep -q '^integrated ' "$WORK/inventory" && has_integrated=true
grep -q '^unknown ' "$WORK/inventory" && has_unknown=true

if [[ "$has_unknown" == true ]]; then
    echo
    echo "Unrecognized GPU accelerator node(s):"
    awk '$1 == "unknown" { print "    " $2 }' "$WORK/inventory"
fi

if [[ "$has_discrete" != true ]]; then
    if [[ "$has_unknown" == true ]]; then
        inconclusive_readings "unrecognized GPU hardware cannot be assumed to be integrated or discrete."
    elif [[ "$has_unified" == true && "$has_integrated" != true ]]; then
        echo
        echo "This Mac uses an Apple unified GPU; no discrete-GPU comparison applies."
        exit 0
    elif [[ "$has_integrated" == true && "$has_unified" != true ]]; then
        echo
        echo "This Mac reports only an integrated GPU. Nothing to test."
        exit 0
    else
        echo
        echo "This Mac reports no discrete GPU. Nothing to test."
        exit 0
    fi
fi

[[ -x "$APP" ]] || { echo "no $APP — run 'make app' first" >&2; exit 1; }

echo
echo "==> control: your desktop, ${PHASE}s (leave it alone)"
if ! collect "$PHASE" "$WORK/before"; then
    inconclusive_readings "the IORegistry GPU samples could not be read during the control phase."
fi
if ! control="$(busy_median "$WORK/before" discrete)"; then
    inconclusive_readings "the control phase contained no discrete-GPU utilization readings."
fi
report "$WORK/before"

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
sleep "$APP_SETTLE_SECONDS"
if ! collect "$PHASE" "$WORK/during"; then
    inconclusive_readings "the IORegistry GPU samples could not be read while Cowsaver was running."
fi
kill "$APP_PID" 2>/dev/null || true
APP_PID=""
if ! running="$(busy_median "$WORK/during" discrete)"; then
    inconclusive_readings "the Cowsaver phase contained no discrete-GPU utilization readings."
fi
report "$WORK/during"

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
