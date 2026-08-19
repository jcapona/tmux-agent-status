#!/usr/bin/env bash
#
# Move the sidebar into the window that was just selected.
#
# Hooked to tmux's own window-change events, not just the plugin's switcher: the
# expectation is "the sidebar is where I am", and most window changes are made
# with tmux's own keys (prefix n, prefix 1, the window list) which never go
# through selection_switch_client.
#
# A no-op unless @agent-sidebar-follow is on. Safe to fire on every event: the
# move is skipped when the sidebar is already in the destination, when the
# destination has its own sidebar, and when the target does not resolve.

set -uo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIDEBAR_TITLE="${SIDEBAR_TITLE:-agent-sidebar}"

# shellcheck source=/dev/null
. "$CURRENT_DIR/lib/selection-targets.sh" 2>/dev/null || exit 0

sidebar_follow_enabled || exit 0

target="${1:-}"
if [ -z "$target" ]; then
    target=$(tmux display-message -p '#{window_id}' 2>/dev/null || true)
fi
[ -n "$target" ] || exit 0

sidebar_follow_to_window "$target"
