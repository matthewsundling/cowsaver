#!/usr/bin/env bash
#
# Live view of the screensaver host and System Settings while you click things.
# Start it, then trigger the behavior under test — activate the saver, click
# Options — and watch for Cowsaver's lines (`startAnimation bounds=…`,
# `hasConfigureSheet queried`, `configureSheet requested`) as they happen.
# Ctrl-C to stop. Pass --all to see the hosts' full output unfiltered.
#
# Usage: scripts/watch-host-logs.sh [--all]

set -euo pipefail

PREDICATE='process == "legacyScreenSaver" OR process == "System Settings" OR subsystem == "com.matthewsundling.cowsaver"'

# NSLog from the appex lands at debug level in the unified log; without
# `--level debug` neither `log stream` nor `log show` returns a single line.
if [[ "${1:-}" == "--all" ]]; then
    echo "WARNING: --all displays broad screensaver-host and System Settings activity. Do not copy or share it without review and redaction." >&2
    exec log stream --level debug --style compact --predicate "$PREDICATE"
fi

echo "Filtered lines may still contain personal paths or context; review copied output before sharing." >&2
log stream --level debug --style compact --predicate "$PREDICATE" \
    | grep -iE --line-buffered 'cowsaver|configure|sheet'
