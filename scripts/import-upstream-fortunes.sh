#!/usr/bin/env bash
#
# Import the fortune-mod cookie database into Resources/fortune-upstream/.
#
# This repository's committed import and manifest are retained for provenance. The script
# records byte counts and SHA-256 digests from a local source directory. It does not verify
# that directory against the reference tarball; verify the input separately.
#
# See Resources/fortune-upstream/provenance.md for the source, licence, and verification scope.
#
# Usage: scripts/import-upstream-fortunes.sh [source-directory]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Resources/fortune-upstream"

UPSTREAM_NAME="fortune-mod"
UPSTREAM_VERSION="9708"
UPSTREAM_URL="https://www.ibiblio.org/pub/linux/games/amusements/fortune/fortune-mod-9708.tar.gz"
UPSTREAM_SHA="1a98a6fd42ef23c8aec9e4a368afb40b6b0ddfb67b5b383ad82a7b78d8e0602a"

SOURCE="${1:-}"
if [[ -z "$SOURCE" ]]; then
    for candidate in \
        /opt/homebrew/share/games/fortunes \
        /usr/local/share/games/fortunes \
        /usr/share/games/fortunes
    do
        [[ -d "$candidate" ]] && { SOURCE="$candidate"; break; }
    done
fi

if [[ -z "$SOURCE" || ! -d "$SOURCE" ]]; then
    echo "error: no fortune data directory found." >&2
    echo "" >&2
    echo "Install it (brew install fortune) or pass the directory explicitly." >&2
    echo "Upstream tarball, pinned:" >&2
    echo "  $UPSTREAM_URL" >&2
    echo "  sha256 $UPSTREAM_SHA" >&2
    exit 1
fi

echo "==> importing from $SOURCE"
mkdir -p "$DEST"

# Reset only imported data; provenance documentation is maintained separately.
find "$DEST" -type f ! -name '*.md' ! -name 'LICENSE' ! -name 'excluded.txt' \
     ! -name 'notes-upstream.txt' ! -name 'readme-upstream.txt' -delete 2>/dev/null || true

MANIFEST="$DEST/manifest.tsv"
{
    printf '# fortune data imported by scripts/import-upstream-fortunes.sh\n'
    printf '# upstream: %s %s\n' "$UPSTREAM_NAME" "$UPSTREAM_VERSION"
    printf '# url: %s\n' "$UPSTREAM_URL"
    printf '# tarball sha256: %s\n' "$UPSTREAM_SHA"
    printf '# imported from: %s\n' "$SOURCE"
    printf '#\n'
    printf '# file\trecords\tbytes\tsha256\n'
} > "$MANIFEST"

total=0
count=0
for path in "$SOURCE"/*; do
    name="$(basename "$path")"
    # .dat/.u8 are strfile binary indexes. The runtime parses text files directly.
    case "$name" in
        *.dat|*.u8|.*) continue ;;
    esac
    # Offensive files are excluded by policy, matching Debian's split into non-free.
    case "$name" in
        *-o) echo "  skipping offensive: $name"; continue ;;
    esac
    [[ -f "$path" ]] || continue

    cp -p "$path" "$DEST/$name"
    records=$(( $(grep -c '^%$' "$path" || true) + 1 ))
    bytes=$(wc -c < "$path" | tr -d ' ')
    sha=$(shasum -a 256 "$path" | awk '{print $1}')
    printf '%s\t%s\t%s\t%s\n' "$name" "$records" "$bytes" "$sha" >> "$MANIFEST"
    total=$(( total + records ))
    count=$(( count + 1 ))
done

printf '#\n# totals\t%s files\t%s records\n' "$count" "$total" >> "$MANIFEST"

echo "==> imported $count files, $total records"
echo "==> manifest: ${MANIFEST#"$ROOT"/}"
