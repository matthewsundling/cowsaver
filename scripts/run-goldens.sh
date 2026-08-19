#!/usr/bin/env bash
#
# Replay the committed compatibility fixtures through the standalone CLI without a test
# framework. `make smoke` invokes this script after building cowsaver-cli.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOLDEN_DIR="${GOLDEN_DIR:-$ROOT/Tests/CowsayKitTests/Golden}"
CLI_PATH="${1:-${COWSAVER_CLI:-}}"

if [[ -z "$CLI_PATH" ]]; then
    echo "error: pass the cowsaver-cli path or set COWSAVER_CLI" >&2
    exit 1
fi

if [[ "$CLI_PATH" != /* ]]; then
    CLI_PATH="$PWD/$CLI_PATH"
fi

if [[ ! -x "$CLI_PATH" ]]; then
    echo "error: cowsaver-cli is not executable: $CLI_PATH" >&2
    exit 1
fi

MANIFEST="$GOLDEN_DIR/manifest.tsv"
CASES="$GOLDEN_DIR/Cases"
EXPECTED="$GOLDEN_DIR/Expected"

for path in "$MANIFEST" "$CASES" "$EXPECTED"; do
    if [[ ! -e "$path" ]]; then
        echo "error: golden path not found: $path" >&2
        exit 1
    fi
done

# Keep cow lookup aligned with the generator. The CLI's existing COWSAVER_COWDIR override
# is set alongside COWPATH because this runner must not depend on the current directory.
export COWPATH="$ROOT/Resources/cows"
export COWSAVER_COWDIR="$COWPATH"

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cowsaver-goldens.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
ln -s "$CLI_PATH" "$temp_dir/cowsaver-think"

passed=0
failed=0

while IFS=$'\t' read -r id cow mode flags width message_case || [[ -n "$id" ]]; do
    [[ -z "$id" ]] && continue

    case "$mode" in
        say) program="$CLI_PATH" ;;
        think) program="$temp_dir/cowsaver-think" ;;
        *)
            echo "mismatch: $id (unknown mode '$mode')" >&2
            failed=$((failed + 1))
            continue
            ;;
    esac

    args=(-f "$cow" -W "$width")
    if [[ "$flags" != "-" ]]; then
        IFS=',' read -r -a flag_tokens <<< "$flags"
        for token in "${flag_tokens[@]}"; do
            case "$token" in
                eyes=*)   args+=(-e "${token#eyes=}") ;;
                tongue=*) args+=(-T "${token#tongue=}") ;;
                *)        args+=("-$token") ;;
            esac
        done
    fi

    actual="$temp_dir/$id.out"
    message_path="$CASES/$message_case.txt"
    expected="$EXPECTED/$id.out"

    if [[ ! -f "$message_path" || ! -f "$expected" ]]; then
        echo "mismatch: $id (missing case or expected file)" >&2
        failed=$((failed + 1))
        continue
    fi

    "$program" "${args[@]}" < "$message_path" > "$actual"
    if cmp "$actual" "$expected" >/dev/null 2>&1; then
        passed=$((passed + 1))
    else
        echo "mismatch: $id" >&2
        cmp "$actual" "$expected" || true
        failed=$((failed + 1))
    fi
done < "$MANIFEST"

total=$((passed + failed))
if (( failed > 0 )); then
    echo "$passed/$total goldens match; $failed mismatch(es)" >&2
    exit 1
fi

echo "$passed/$total goldens match"
