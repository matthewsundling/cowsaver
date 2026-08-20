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

PREDICATE='process == "legacyScreenSaver" OR process == "System Settings"'

# NSLog from the appex lands at debug level in the unified log; without
# `--level debug` neither `log stream` nor `log show` returns a single line.
if [[ "${1:-}" == "--all" ]]; then
    exec log stream --level debug --style compact --predicate "$PREDICATE"
fi

log stream --level debug --style compact --predicate "$PREDICATE" \
    | grep -iE --line-buffered 'cowsaver|configure|sheet'
