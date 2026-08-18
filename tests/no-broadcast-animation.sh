#!/usr/bin/env bash

set -euo pipefail

# Verify the collector no longer broadcasts USR2 animation signals.
# Spinner animation is now local to each sidebar process, driven by
# its own read-timeout timer. This eliminates N signal deliveries +
# a tmux list-panes IPC call every 0.25s.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 1. The collector must not call signal_sidebar_clients with USR2.
if grep -q 'signal_sidebar_clients.*USR2' "$REPO_DIR/scripts/sidebar-collector.sh"; then
    echo "FAIL: collector still broadcasts USR2 animation signals" >&2
    grep -n 'signal_sidebar_clients.*USR2' "$REPO_DIR/scripts/sidebar-collector.sh" >&2
    exit 1
fi

# 2. The sidebar must still have local animation: ANIMATE_TICK set in
#    the main loop when _HAS_WORKING, independent of USR2.
if ! grep -q '_HAS_WORKING.*&&.*ANIMATE_TICK=1' "$REPO_DIR/scripts/sidebar.sh"; then
    echo "FAIL: sidebar does not set ANIMATE_TICK locally in main loop" >&2
    exit 1
fi

# 3. The USR2 trap handler is kept for backward compatibility but is
#    no longer the animation driver.
if ! grep -q 'trap handle_animation_signal USR2' "$REPO_DIR/scripts/sidebar.sh"; then
    echo "FAIL: sidebar lost USR2 trap handler (backward compat)" >&2
    exit 1
fi

echo "no-broadcast-animation checks passed"
