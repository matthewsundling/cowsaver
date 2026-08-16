#!/usr/bin/env bash
#
# Sign and notarize Cowsaver.saver for distribution.
#
# This optional release step signs a bundle for distribution outside a local build. It
# requires explicit Developer ID and notary credentials supplied through environment variables.
#
#   DEVELOPER_ID     e.g. "Developer ID Application: Your Name (TEAMID)"
#   KEYCHAIN_PROFILE a notarytool keychain profile, created once with:
#                      xcrun notarytool store-credentials "AC_PASSWORD" \
#                        --apple-id you@example.com --team-id TEAMID --password <app-specific>
#
# Usage: DEVELOPER_ID="..." KEYCHAIN_PROFILE="AC_PASSWORD" scripts/sign-and-notarize.sh
#
# The signing sequence follows Cannonade's `.saver` walkthrough:
# https://www.cannonade.net/blog.php?id=1872

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAVER="$ROOT/build/Cowsaver.saver"
ZIP="$ROOT/build/Cowsaver.saver.zip"

if [[ -z "${DEVELOPER_ID:-}" ]]; then
    echo "DEVELOPER_ID is not set." >&2
    echo "" >&2
    echo "This is optional. Most people cloning this repo do not have a Developer ID and" >&2
    echo "do not need one: 'make install' produces a working unsigned screensaver." >&2
    echo "See the README." >&2
    exit 1
fi

[[ -d "$SAVER" ]] || { echo "no $SAVER — run 'make saver' first" >&2; exit 1; }

echo "==> signing"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$SAVER"
codesign --verify --deep --strict --verbose=2 "$SAVER"

if [[ -z "${KEYCHAIN_PROFILE:-}" ]]; then
    echo "==> signed, but KEYCHAIN_PROFILE is unset so notarization was skipped."
    echo "    A signed-but-unnotarized bundle still prompts on other machines."
    exit 0
fi

echo "==> notarizing (this waits on Apple; it can take several minutes)"
rm -f "$ZIP"
ditto -c -k --keepParent "$SAVER" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> stapling"
xcrun stapler staple "$SAVER"
xcrun stapler validate "$SAVER"

echo "==> done: $SAVER is signed, notarized and stapled"
