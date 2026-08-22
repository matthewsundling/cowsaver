#!/usr/bin/env bash
#
# Deterministic checks for the diagnostic commands. All host-facing commands are supplied
# by PATH stubs so this script does not read unified logs or user diagnostics.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cowsaver-diagnostic-tools.XXXXXX")"
STUBS="$TEMP_ROOT/stubs"
WORK="$TEMP_ROOT/work"
DIAGNOSTICS="$TEMP_ROOT/diagnostics"
SAFE_PATH="$STUBS:/usr/bin:/bin"

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    grep -F "$2" "$1" >/dev/null || fail "expected $1 to contain: $2"
}

assert_not_contains() {
    if grep -F "$2" "$1" >/dev/null; then
        fail "expected $1 not to contain: $2"
    fi
}

assert_file_equals() {
    expected="$1"
    actual="$2"
    if ! diff -u "$expected" "$actual" >/dev/null; then
        diff -u "$expected" "$actual" >&2 || true
        fail "unexpected contents in $actual"
    fi
}

mkdir -p "$STUBS" "$WORK"

cat > "$STUBS/sw_vers" <<'EOF'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
    -productVersion) echo "testOS" ;;
    -buildVersion) echo "testBuild" ;;
    '') echo "ProductName:\ttestOS" ;;
    *) echo "unexpected sw_vers arguments: $*" >&2; exit 1 ;;
esac
EOF

cat > "$STUBS/uname" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = "-m" ]; then
    echo "testarch"
else
    echo "unexpected uname arguments: $*" >&2
    exit 1
fi
EOF

cat > "$STUBS/pkgutil" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = "--pkg-info=com.apple.pkg.CLTools_Executables" ]; then
    echo "version: test-clt"
else
    echo "unexpected pkgutil arguments: $*" >&2
    exit 1
fi
EOF

cat > "$STUBS/swiftc" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = "--version" ]; then
    echo "Swift test compiler"
else
    echo "unexpected swiftc arguments: $*" >&2
    exit 1
fi
EOF

cat > "$STUBS/date" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = "+%Y%m%d-%H%M%S" ]; then
    echo "20260822-120000"
else
    echo "unexpected date arguments: $*" >&2
    exit 1
fi
EOF

cat > "$STUBS/log" <<'EOF'
#!/usr/bin/env bash
set -eu
predicate='process == "legacyScreenSaver" OR process == "System Settings" OR subsystem == "com.matthewsundling.cowsaver"'
case "${1:-}" in
    show)
        [ "$#" -eq 9 ] || { echo "unexpected log show arguments: $*" >&2; exit 1; }
        [ "$2" = "--last" ] && [ "$3" = "30m" ] && [ "$4" = "--info" ] && \
            [ "$5" = "--debug" ] && [ "$6" = "--style" ] && [ "$7" = "compact" ] && \
            [ "$8" = "--predicate" ] && [ "$9" = "$predicate" ] || {
            echo "unexpected log show arguments: $*" >&2
            exit 1
        }
        ;;
    stream)
        [ "$#" -eq 7 ] || { echo "unexpected log stream arguments: $*" >&2; exit 1; }
        [ "$2" = "--level" ] && [ "$3" = "debug" ] && [ "$4" = "--style" ] && \
            [ "$5" = "compact" ] && [ "$6" = "--predicate" ] && [ "$7" = "$predicate" ] || {
            echo "unexpected log stream arguments: $*" >&2
            exit 1
        }
        ;;
    *)
        echo "unexpected log command: $*" >&2
        exit 1
        ;;
esac
printf '%s\n' \
    '2026-08-22 legacyScreenSaver: unrelated host activity' \
    '2026-08-22 Cowsaver: render started' \
    '2026-08-22 System Settings: configureSheet requested' \
    '2026-08-22 unrelated process: unrelated fixture output'
EOF

cat > "$STUBS/make" <<EOF
#!/usr/bin/env bash
set -eu
if [ "\$#" -eq 3 ] && [ "\$1" = "-C" ] && [ "\$2" = "$ROOT" ] && [ "\$3" = "doctor" ]; then
    echo "doctor fixture"
else
    echo "unexpected make arguments: \$*" >&2
    exit 1
fi
EOF

chmod +x "$STUBS"/*

absent_doctor="$TEMP_ROOT/doctor-absent.txt"
PATH="$SAFE_PATH" /usr/bin/make -f "$ROOT/Makefile" -C "$WORK" doctor \
    INSTALL_DIR="$TEMP_ROOT/install" SWIFTC=swiftc > "$absent_doctor" 2>&1
assert_contains "$absent_doctor" 'cowsay:          not installed'
assert_not_contains "$absent_doctor" 'command not found'

cat > "$STUBS/cowsay" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = "--version" ] && [ "$#" -eq 1 ]; then
    printf '%s\n' 'Cowsay test version 9.9.9' 'unused version detail'
else
    echo "unexpected cowsay arguments: $*" >&2
    exit 1
fi
EOF
chmod +x "$STUBS/cowsay"

present_doctor="$TEMP_ROOT/doctor-present.txt"
PATH="$SAFE_PATH" /usr/bin/make -f "$ROOT/Makefile" -C "$WORK" doctor \
    INSTALL_DIR="$TEMP_ROOT/install" SWIFTC=swiftc > "$present_doctor" 2>&1
assert_contains "$present_doctor" 'cowsay:          Cowsay test version 9.9.9'
assert_not_contains "$present_doctor" 'unused version detail'

capture_output="$TEMP_ROOT/capture-output.txt"
PATH="$SAFE_PATH" COWSAVER_DIAGNOSTICS_ROOT="$DIAGNOSTICS" \
    bash "$ROOT/scripts/capture-host-logs.sh" 30m > "$capture_output" 2>&1
OUT="$DIAGNOSTICS/20260822-120000"
for file in sw_vers.txt doctor.txt host-full.log cowsaver.log sheet.log; do
    [ -f "$OUT/$file" ] || fail "missing capture file: $file"
done
assert_contains "$OUT/host-full.log" 'legacyScreenSaver: unrelated host activity'
assert_contains "$OUT/host-full.log" 'unrelated process: unrelated fixture output'
printf '%s\n' '2026-08-22 Cowsaver: render started' > "$TEMP_ROOT/expected-cowsaver.log"
printf '%s\n' '2026-08-22 System Settings: configureSheet requested' > "$TEMP_ROOT/expected-sheet.log"
assert_file_equals "$TEMP_ROOT/expected-cowsaver.log" "$OUT/cowsaver.log"
assert_file_equals "$TEMP_ROOT/expected-sheet.log" "$OUT/sheet.log"
assert_contains "$capture_output" 'Review every file before sharing'
assert_contains "$capture_output" 'doctor.txt, sw_vers.txt, cowsaver.log, and sheet.log'
assert_contains "$capture_output" 'Do not share host-full.log unless a maintainer specifically requests it'

watch_default="$TEMP_ROOT/watch-default.txt"
PATH="$SAFE_PATH" bash "$ROOT/scripts/watch-host-logs.sh" > "$watch_default" 2>&1
assert_contains "$watch_default" 'Filtered lines may still contain personal paths or context'
assert_contains "$watch_default" 'Cowsaver: render started'
assert_contains "$watch_default" 'configureSheet requested'
assert_not_contains "$watch_default" 'unrelated host activity'
assert_not_contains "$watch_default" 'unrelated fixture output'

watch_all="$TEMP_ROOT/watch-all.txt"
PATH="$SAFE_PATH" bash "$ROOT/scripts/watch-host-logs.sh" --all > "$watch_all" 2>&1
assert_contains "$watch_all" 'WARNING: --all displays broad screensaver-host and System Settings activity'
assert_contains "$watch_all" 'unrelated host activity'
assert_contains "$watch_all" 'unrelated fixture output'

echo "diagnostic tooling tests: ok"
