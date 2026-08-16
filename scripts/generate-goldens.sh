#!/usr/bin/env bash
#
# Generate compatibility fixtures from a local cowsay 3.8.4 installation. `make golden`
# invokes this script; CI compares the committed fixtures and separately regenerates them.

set -euo pipefail

REQUIRED_VERSION="3.8.4"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOLDEN="$ROOT/Tests/CowsayKitTests/Golden"
CASES="$GOLDEN/Cases"
EXPECTED="$GOLDEN/Expected"
MANIFEST="$GOLDEN/manifest.tsv"

# --- Required cowsay version -------------------------------------------------------

command -v cowsay   >/dev/null || { echo "error: cowsay not found (brew install cowsay)" >&2; exit 1; }
command -v cowthink >/dev/null || { echo "error: cowthink not found" >&2; exit 1; }

if ! cowsay --version 2>&1 | grep -q "version $REQUIRED_VERSION"; then
    echo "error: goldens are pinned to cowsay $REQUIRED_VERSION, but this is:" >&2
    cowsay --version 2>&1 | head -1 >&2
    echo "" >&2
    echo "Regenerating against a different version would replace the fixtures generated" >&2
    echo "by cowsay $REQUIRED_VERSION. To update the pinned version, change REQUIRED_VERSION" >&2
    echo "here and review the complete fixture diff." >&2
    exit 1
fi

# Generate fixtures from Cowsaver's bundled cowfiles.
export COWPATH="$ROOT/Resources/cows"
export COWSAY_ONLY_COWPATH=1

rm -rf "$CASES" "$EXPECTED"
mkdir -p "$CASES" "$EXPECTED"
: > "$MANIFEST"

# --- Message cases -----------------------------------------------------------------
#
# Files piped to stdin preserve empty input and embedded newlines exactly.

write_case() { printf '%s' "$2" > "$CASES/$1.txt"; }

write_case one-line          'Moo world'
write_case two-lines         'this message is long enough to wrap onto exactly two lines ok'
write_case multi-line        "$(python3 -c "print(' '.join(['word']*40))")"
write_case long-word         "$(python3 -c "print('z'*90)")"
write_case empty             ''
write_case metachars         'cost $eyes and \ and @ and "q" and ${tongue}'
write_case embedded-newlines $'first line\nsecond line\nthird line\n'
write_case blank-paragraphs  $'para one here\n\npara two here\n\npara three\n'
write_case tabs              $'a\tb\t\tc\n\tindented\n'
write_case width-38          "$(python3 -c "print('x'*38)")"
write_case width-39          "$(python3 -c "print('x'*39)")"
write_case width-40          "$(python3 -c "print('x'*40)")"
write_case width-41          "$(python3 -c "print('x'*41)")"
write_case indented-para     $'first paragraph\n  indented starts a new one\n'
write_case trailing-space    'trailing space   '
# cowsay does not `use utf8`, so this case wraps mid-character and emits invalid UTF-8.
write_case non-ascii         "$(python3 -c "print('é'*30 + ' 日本語 café naïve')")"
# Text::Wrap drops runs of pure break characters; each case renders as an empty balloon.
write_case spaces-only       '   '
write_case tab-only          $'\t'
write_case crlf-only         $'\r\n'
write_case blank-lines-only  $'\n\n\n'

ALL_MESSAGE_CASES=(one-line two-lines multi-line long-word empty metachars
                   embedded-newlines blank-paragraphs tabs width-38 width-39 width-40
                   width-41 indented-para trailing-space non-ascii spaces-only tab-only
                   crlf-only blank-lines-only)

# --- Emit one golden ---------------------------------------------------------------
#
# $1 id  $2 cow  $3 mode(say|think)  $4 flags  $5 width  $6 case
#
# `flags` is a comma-separated list the test harness parses back into a Face:
# single letters are face modes, `eyes=XX` and `tongue=XX` are -e and -T. `-` means none.

emit() {
    local id="$1" cow="$2" mode="$3" flags="$4" width="$5" case_name="$6"
    local -a args=(-f "$cow" -W "$width")

    if [[ "$flags" != "-" ]]; then
        local IFS=','
        for token in $flags; do
            case "$token" in
                eyes=*)   args+=(-e "${token#eyes=}") ;;
                tongue=*) args+=(-T "${token#tongue=}") ;;
                *)        args+=("-$token") ;;
            esac
        done
    fi

    local program=cowsay
    [[ "$mode" == "think" ]] && program=cowthink

    "$program" "${args[@]}" < "$CASES/$case_name.txt" > "$EXPECTED/$id.out"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$cow" "$mode" "$flags" "$width" "$case_name" \
        >> "$MANIFEST"
}

# --- Tier A: every bundled cowfile x {say, think} -----------------------------------
# Exercises every bundled static cowfile in speech and thought modes.
for path in "$ROOT"/Resources/cows/*.cow; do
    cow="$(basename "$path" .cow)"
    emit "A-$cow-say"   "$cow" say   - 40 one-line
    emit "A-$cow-think" "$cow" think - 40 one-line
done

# --- Tier B: every message shape x three wrap widths --------------------------------
# Exercises wrapping boundaries and message-shape behavior at three widths.
for width in 30 40 60; do
    for case_name in "${ALL_MESSAGE_CASES[@]}"; do
        emit "B-w$width-$case_name" default say - "$width" "$case_name"
    done
done

# --- Tier C: face modes ------------------------------------------------------------
# Includes -g and -p, whose eyes ($$ and @@) are what the single-pass render protects.
for cow in default stegosaurus; do
    for flags in - b d g p s t w y; do
        emit "C-$cow-say-$flags"   "$cow" say   "$flags" 40 one-line
        emit "C-$cow-think-$flags" "$cow" think "$flags" 40 one-line
    done
done

# --- Tier D: interactions ----------------------------------------------------------
# Combines message shape, face settings, and width.
for case_name in one-line long-word metachars blank-paragraphs; do
    for flags in "d,y" "eyes=AB" "b,tongue=QQ"; do
        for width in 30 60; do
            id="D-${case_name}-${flags//[,=]/_}-w${width}"
            emit "$id" stegosaurus say "$flags" "$width" "$case_name"
        done
    done
done

# --- Tier E: the -n path ------------------------------------------------------------
# `-n` disables wrapping and expands tabs to 8-column stops. It is separate from `fill` and
# is the only path that applies tab stops.
for case_name in tabs one-line long-word embedded-newlines trailing-space; do
    emit "E-n-$case_name" default say n 40 "$case_name"
done

sort -o "$MANIFEST" "$MANIFEST"
echo "generated $(wc -l < "$MANIFEST" | tr -d ' ') goldens from cowsay $REQUIRED_VERSION"
