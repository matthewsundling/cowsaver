#!/usr/bin/env bash
# Deterministic GPU diagnostic tests. Fixtures and host-facing commands stay inside a
# temporary directory, so the developer Mac's GPU and built Cowsaver app are never used.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GPU_CHECK="$ROOT/scripts/gpu-check.sh"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cowsaver-gpu-check.XXXXXX")"
IOREG_STUB="$TEMP_ROOT/ioreg"
APP_STUB="$TEMP_ROOT/Cowsaver"

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    if ! grep -F "$2" "$1" >/dev/null; then
        sed -n '1,200p' "$1" >&2
        fail "expected $1 to contain: $2"
    fi
}

assert_not_contains() {
    if grep -F "$2" "$1" >/dev/null; then
        fail "expected $1 not to contain: $2"
    fi
}

assert_status() {
    [[ "$RUN_STATUS" -eq "$1" ]] || {
        sed -n '1,200p' "$RUN_OUTPUT" >&2
        fail "expected exit $1, got $RUN_STATUS"
    }
}

assert_launches() {
    local expected="$1" actual=0
    if [[ -f "$CASE_ROOT/app-launches" ]]; then
        actual="$(wc -l < "$CASE_ROOT/app-launches" | tr -d ' ')"
    fi
    [[ "$actual" -eq "$expected" ]] || fail "$CASE_ROOT expected $expected app launches, got $actual"
}

assert_app_stopped() {
    local pid attempts=0
    [[ -f "$CASE_ROOT/app-pid" ]] || fail "fake app did not record its process id"
    pid="$(cat "$CASE_ROOT/app-pid")"
    while kill -0 "$pid" 2>/dev/null && [[ "$attempts" -lt 20 ]]; do
        sleep 0.05
        attempts=$(( attempts + 1 ))
    done
    if kill -0 "$pid" 2>/dev/null; then
        fail "fake app process $pid was not stopped"
    fi
}

# Entries use name:utilization:watts. A utilization of `missing` emits a realistic
# PerformanceStatistics dictionary without the exact key the diagnostic requires.
write_snapshot() {
    local file="$1" entry name remainder utilization watts
    shift
    : > "$file"
    for entry in "$@"; do
        name="${entry%%:*}"
        remainder="${entry#*:}"
        utilization="${remainder%%:*}"
        watts="${remainder#*:}"
        printf '+-o %s  <class %s, id 0x100000001, registered, matched, active, busy 0>\n' \
            "$name" "$name" >> "$file"
        if [[ "$utilization" == missing ]]; then
            printf '  |   "PerformanceStatistics" = {"GPU Core Utilization"=1,"textureCount"=42}\n' \
                >> "$file"
        elif [[ "$watts" == none ]]; then
            printf '  |   "PerformanceStatistics" = {"Device Utilization %% at cur p-state"=99,"Device Utilization %%"=%s,"textureCount"=42}\n' \
                "$utilization" >> "$file"
        else
            printf '  |   "PerformanceStatistics" = {"Device Utilization %% at cur p-state"=99,"Device Utilization %%"=%s,"Total Power(W)"=%s,"textureCount"=42}\n' \
                "$utilization" "$watts" >> "$file"
        fi
    done
}

new_case() {
    CASE_ROOT="$TEMP_ROOT/$1"
    mkdir -p "$CASE_ROOT"
}

copy_inventory_to_phases() {
    cp "$CASE_ROOT/inventory.ioreg" "$CASE_ROOT/before.ioreg"
    cp "$CASE_ROOT/inventory.ioreg" "$CASE_ROOT/during.ioreg"
}

run_gpu_check() {
    RUN_OUTPUT="$CASE_ROOT/output.txt"
    set +e
    COWSAVER_GPU_IOREG_COMMAND="$IOREG_STUB" \
        COWSAVER_GPU_APP="$APP_STUB" \
        COWSAVER_GPU_SAMPLE_COUNT=3 \
        COWSAVER_GPU_APP_SETTLE_SECONDS=0.5 \
        GPU_CASE_ROOT="$CASE_ROOT" \
        bash "$GPU_CHECK" 1 > "$RUN_OUTPUT" 2>&1
    RUN_STATUS=$?
    set -e
}

cat > "$IOREG_STUB" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "$#" -ne 3 ] || [ "$1" != "-rc" ] || [ "$2" != "IOAccelerator" ] || [ "$3" != "-w0" ]; then
    echo "unexpected ioreg arguments: $*" >&2
    exit 1
fi
if [ -f "$GPU_CASE_ROOT/fail-ioreg" ]; then
    exit 9
fi
calls=0
if [ -f "$GPU_CASE_ROOT/ioreg-calls" ]; then
    calls="$(cat "$GPU_CASE_ROOT/ioreg-calls")"
fi
calls=$(( calls + 1 ))
printf '%s\n' "$calls" > "$GPU_CASE_ROOT/ioreg-calls"
if [ "$calls" -eq 1 ]; then
    cat "$GPU_CASE_ROOT/inventory.ioreg"
elif [ "$calls" -gt 4 ]; then
    cat "$GPU_CASE_ROOT/during.ioreg"
else
    cat "$GPU_CASE_ROOT/before.ioreg"
fi
EOF

cat > "$APP_STUB" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "$#" -ne 1 ] || [ "$1" != "--fullscreen" ]; then
    echo "unexpected app arguments: $*" >&2
    exit 1
fi
printf '%s\n' "$*" >> "$GPU_CASE_ROOT/app-launches"
printf '%s\n' "$$" > "$GPU_CASE_ROOT/app-pid"
: > "$GPU_CASE_ROOT/app-running"
exec /bin/sleep 30
EOF

chmod +x "$IOREG_STUB" "$APP_STUB"

new_case unified-only
write_snapshot "$CASE_ROOT/inventory.ioreg" \
    'AppleGPUAccelerator:3:none' \
    'AGXAcceleratorG14G:4:none'
copy_inventory_to_phases
run_gpu_check
assert_status 0
assert_contains "$RUN_OUTPUT" 'unified     AppleGPUAccelerator'
assert_contains "$RUN_OUTPUT" 'unified     AGXAcceleratorG14G'
assert_contains "$RUN_OUTPUT" 'This Mac uses an Apple unified GPU; no discrete-GPU comparison applies.'
assert_launches 0

new_case integrated-only
write_snapshot "$CASE_ROOT/inventory.ioreg" 'IntelAccelerator:3:none'
copy_inventory_to_phases
run_gpu_check
assert_status 0
assert_contains "$RUN_OUTPUT" 'integrated  IntelAccelerator'
assert_contains "$RUN_OUTPUT" 'This Mac reports only an integrated GPU. Nothing to test.'
assert_launches 0

new_case quiet-amd
write_snapshot "$CASE_ROOT/inventory.ioreg" \
    'IntelAccelerator:3:none' \
    'AMDGraphicsAccelerator:4:17'
cp "$CASE_ROOT/inventory.ioreg" "$CASE_ROOT/before.ioreg"
write_snapshot "$CASE_ROOT/during.ioreg" \
    'IntelAccelerator:2:none' \
    'AMDGraphicsAccelerator:6:16'
run_gpu_check
assert_status 0
assert_contains "$RUN_OUTPUT" 'integrated  IntelAccelerator'
assert_contains "$RUN_OUTPUT" 'discrete    AMDGraphicsAccelerator'
assert_contains "$RUN_OUTPUT" 'PASS — Cowsaver added no discrete-GPU work: 6% median against 4%'
assert_launches 1

new_case raised-ati
write_snapshot "$CASE_ROOT/inventory.ioreg" \
    'IntelAccelerator:3:none' \
    'ATIRadeonAccelerator:4:17'
cp "$CASE_ROOT/inventory.ioreg" "$CASE_ROOT/before.ioreg"
write_snapshot "$CASE_ROOT/during.ioreg" \
    'IntelAccelerator:2:none' \
    'ATIRadeonAccelerator:12:19'
run_gpu_check
assert_status 1
assert_contains "$RUN_OUTPUT" 'FAIL — the discrete GPU ran at 12% under Cowsaver, against 4%'
assert_launches 1

new_case busy-nvidia
write_snapshot "$CASE_ROOT/inventory.ioreg" \
    'IntelAccelerator:3:none' \
    'NVAccelerator:16:18' \
    'NVIDIAGraphicsAccelerator:16:18'
cp "$CASE_ROOT/inventory.ioreg" "$CASE_ROOT/before.ioreg"
cp "$CASE_ROOT/inventory.ioreg" "$CASE_ROOT/during.ioreg"
run_gpu_check
assert_status 2
assert_contains "$RUN_OUTPUT" 'INCONCLUSIVE — your desktop is already using the discrete GPU heavily'
assert_launches 0

new_case unknown-only
write_snapshot "$CASE_ROOT/inventory.ioreg" 'MysteryGraphicsAccelerator:7:none'
copy_inventory_to_phases
run_gpu_check
assert_status 2
assert_contains "$RUN_OUTPUT" 'unknown     MysteryGraphicsAccelerator'
assert_contains "$RUN_OUTPUT" 'INCONCLUSIVE — unrecognized GPU hardware cannot be assumed to be integrated or discrete.'
assert_launches 0

new_case mixed-with-unknown
write_snapshot "$CASE_ROOT/inventory.ioreg" \
    'AppleGPUAccelerator:99:none' \
    'RadeonGraphicsAccelerator:4:17' \
    'MysteryGraphicsAccelerator:100:none'
cp "$CASE_ROOT/inventory.ioreg" "$CASE_ROOT/before.ioreg"
write_snapshot "$CASE_ROOT/during.ioreg" \
    'AppleGPUAccelerator:99:none' \
    'RadeonGraphicsAccelerator:5:17' \
    'MysteryGraphicsAccelerator:100:none'
run_gpu_check
assert_status 0
assert_contains "$RUN_OUTPUT" 'unified     AppleGPUAccelerator'
assert_contains "$RUN_OUTPUT" 'discrete    RadeonGraphicsAccelerator'
assert_contains "$RUN_OUTPUT" 'unknown     MysteryGraphicsAccelerator'
assert_contains "$RUN_OUTPUT" 'PASS — Cowsaver added no discrete-GPU work: 5% median against 4%'
assert_launches 1

new_case empty
: > "$CASE_ROOT/inventory.ioreg"
copy_inventory_to_phases
run_gpu_check
assert_status 2
assert_contains "$RUN_OUTPUT" 'INCONCLUSIVE — no GPU accelerator nodes were found in the IORegistry data.'
assert_launches 0

new_case malformed
printf '%s\n' 'not an IORegistry accelerator record' > "$CASE_ROOT/inventory.ioreg"
copy_inventory_to_phases
run_gpu_check
assert_status 2
assert_contains "$RUN_OUTPUT" 'INCONCLUSIVE — no GPU accelerator nodes were found in the IORegistry data.'
assert_launches 0

new_case missing-control
write_snapshot "$CASE_ROOT/inventory.ioreg" 'AMDGraphicsAccelerator:4:17'
write_snapshot "$CASE_ROOT/before.ioreg" 'AMDGraphicsAccelerator:missing:none'
write_snapshot "$CASE_ROOT/during.ioreg" 'AMDGraphicsAccelerator:4:17'
run_gpu_check
assert_status 2
assert_contains "$RUN_OUTPUT" 'INCONCLUSIVE — the control phase contained no discrete-GPU utilization readings.'
assert_launches 0

new_case missing-running
write_snapshot "$CASE_ROOT/inventory.ioreg" 'AMDGraphicsAccelerator:4:17'
cp "$CASE_ROOT/inventory.ioreg" "$CASE_ROOT/before.ioreg"
write_snapshot "$CASE_ROOT/during.ioreg" 'AMDGraphicsAccelerator:missing:none'
run_gpu_check
assert_status 2
assert_contains "$RUN_OUTPUT" 'INCONCLUSIVE — the Cowsaver phase contained no discrete-GPU utilization readings.'
assert_launches 1
assert_app_stopped

new_case failed-ioreg
: > "$CASE_ROOT/fail-ioreg"
: > "$CASE_ROOT/inventory.ioreg"
copy_inventory_to_phases
run_gpu_check
assert_status 2
assert_contains "$RUN_OUTPUT" 'INCONCLUSIVE — the IORegistry GPU inventory could not be read.'
assert_launches 0

echo "gpu diagnostic tests: ok"
