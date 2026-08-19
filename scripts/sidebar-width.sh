#!/usr/bin/env bash
#
# Re-assert the sidebar's configured width.
#
# A tmux pane is not pinned: when a pane opens or closes, tmux redistributes the
# window's columns and the sidebar grows or shrinks with everything else. A
# sidebar that arrives at 42 is a third of the window a moment later, which
# reads as "it changes width when I switch windows" even though the move set it
# correctly.
#
# Hooked to window-layout-changed. Only resizes when the width actually differs,
# so it cannot drive itself in a loop.

set -uo pipefail

SIDEBAR_TITLE="${SIDEBAR_TITLE:-agent-sidebar}"

want=$(tmux show-option -gqv "@agent-sidebar-width" 2>/dev/null)
[ -z "$want" ] && want=42
case "$want" in ''|*[!0-9]*) exit 0 ;; esac

tmux list-panes -a -F '#{pane_id}|#{window_id}|#{window_width}|#{pane_width}|#{pane_title}' 2>/dev/null \
| while IFS='|' read -r pane win wwidth pwidth title; do
    [ "$title" = "$SIDEBAR_TITLE" ] || continue
    [ "$pwidth" = "$want" ] && continue
    # Never take more than half the window: on a narrow window the configured
    # width may simply not fit, and forcing it would squeeze everything else.
    [ -n "$wwidth" ] && [ "$wwidth" -gt 0 ] 2>/dev/null || continue
    [ "$want" -ge $(( wwidth / 2 )) ] 2>/dev/null && continue
    tmux resize-pane -t "$pane" -x "$want" 2>/dev/null || true
done
