#!/usr/bin/env bash
#
# Copy fortune data already on this machine into Cowsaver's container.
#
# The bundled curated corpus remains unchanged. This script adds a user's own local
# fortune files as a separate collection.
#
# This script runs outside the screensaver sandbox. It copies files that
# `legacyScreenSaver.appex` cannot read directly into that host's container.
#
# Usage:
#   scripts/import-fortunes.sh                 # fortunes
#   scripts/import-fortunes.sh --dry-run       # show what would be copied
#   scripts/import-fortunes.sh --list          # just show what was found

set -euo pipefail

CONTAINER="$HOME/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data"
DEST="$CONTAINER/Library/Application Support/Cowsaver"

FORTUNE_DIRS=(
    /opt/homebrew/share/games/fortunes
    /usr/local/share/games/fortunes
    /usr/share/games/fortunes
    /opt/homebrew/share/fortune
    /usr/local/share/fortune
)
dry_run=false
list_only=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)   dry_run=true ;;
        --list)      list_only=true; dry_run=true ;;
        -h|--help)   sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# --- Sanity ------------------------------------------------------------------------

if [[ ! -d "$CONTAINER" ]]; then
    warn "error: the screensaver container does not exist yet:"
    warn "  $CONTAINER"
    warn ""
    warn "macOS creates it the first time a legacy screensaver runs. Open"
    warn "System Settings > Wallpaper > Screen Saver, let any screensaver start once,"
    warn "then run this again."
    exit 1
fi

# --- Copy ---------------------------------------------------------------------------

# $1 label, $2 destination subdirectory, $3... candidate source directories
import() {
    local label="$1" subdir="$2"; shift 2
    local target="$DEST/$subdir"
    local found=0 copied=0 skipped=0

    for source in "$@"; do
        [[ -d "$source" ]] || continue
        found=1
        say "  source: $source"

        while IFS= read -r -d '' file; do
            local base relative
            relative="${file#"$source"/}"
            base="$(basename "$file")"

            # .dat/.u8 are strfile binary indexes. Cowsaver parses the text files directly.
            case "$base" in
                *.dat|*.u8|.*) skipped=$((skipped+1)); continue ;;
            esac
            # fortune's convention for separately distributed content: an -o suffix on the
            # filename, or a directory *component* exactly equal to "off" somewhere above
            # it. Component matching, not a substring test: "handoff/quotes" and
            # "office/quotes" are ordinary content, not the "off/" convention.
            local skip_by_convention=false
            case "$base" in
                *-o) skip_by_convention=true ;;
            esac
            if [[ "$skip_by_convention" == false ]]; then
                local dir dir_parts part
                dir="$(dirname "$relative")"
                if [[ "$dir" != "." ]]; then
                    IFS='/' read -ra dir_parts <<< "$dir"
                    for part in "${dir_parts[@]}"; do
                        if [[ "$part" == "off" ]]; then
                            skip_by_convention=true
                            break
                        fi
                    done
                fi
            fi
            if [[ "$skip_by_convention" == true ]]; then
                skipped=$((skipped+1))
                continue
            fi

            if [[ "$dry_run" == true ]]; then
                say "    would copy: $relative"
            else
                mkdir -p "$target/$(dirname "$relative")"
                cp -p "$file" "$target/$relative"
            fi
            copied=$((copied+1))
        done < <(find "$source" -type f -print0 2>/dev/null | sort -z)
    done

    if [[ "$found" -eq 0 ]]; then
        say "  none found (looked in: $*)"
    else
        say "  $label: $copied file(s), $skipped skipped"
    fi
    say ""
}

say "Cowsaver import"
say "destination: $DEST"
[[ "$dry_run" == true ]] && say "(dry run -- nothing will be written)"
say ""

say "Fortunes:"
import "fortunes" "fortune-user" "${FORTUNE_DIRS[@]}"

if [[ "$list_only" == true || "$dry_run" == true ]]; then
    exit 0
fi

say "Done. Stop and start the screensaver to load the imported fortunes."
say ""
say "Note: imported content stays on this machine. Nothing was downloaded."
