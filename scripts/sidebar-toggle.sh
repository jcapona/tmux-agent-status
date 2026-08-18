#!/usr/bin/env bash

# Show or toggle the agent sidebar pane.
#
# Usage: sidebar-toggle.sh [--toggle] [target-window]
#
#   default    open the sidebar, or focus it when already visible
#   --toggle   as above, but close it when already visible
#
# The two modes exist because the callers want different things. A keybinding
# should toggle: pressing the same key twice is expected to undo itself. The
# session-created hook and the start-up sweep must not -- they run over windows
# that may already have a sidebar, and closing those would be the opposite of
# what they are for.
#
# Optional target window (e.g. "session:window"). Defaults to the current one.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIDEBAR_TITLE="agent-sidebar"
STATUS_DIR="$HOME/.cache/tmux-agent-status"

MODE="show"
if [ "${1:-}" = "--toggle" ]; then
    MODE="toggle"
    shift
fi
TARGET="${1:-}"

# Read configured width.
width=$(tmux show-option -gqv "@agent-sidebar-width" 2>/dev/null)
[ -z "$width" ] && width=42

# Read per-window setting: when on, only the first window in a session gets
# the full renderer; subsequent windows get a lightweight display proxy.
case "$(tmux show-option -gqv "@agent-sidebar-per-window")" in
    0|off|false|no) sidebar_per_window=0 ;;
    *)              sidebar_per_window=1 ;;
esac

# Resolve the session name for the target window.
if [ -n "$TARGET" ]; then
    session_name=$(tmux display-message -t "$TARGET" -p '#{session_name}' 2>/dev/null || echo "")
else
    session_name=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")
fi

# Check whether a renderer is already running for this session.
has_renderer=0
if [ -n "$session_name" ] && [ "$sidebar_per_window" = "1" ]; then
    renderer_pid_file="$STATUS_DIR/.sidebar-renderer.$session_name.pid"
    if [ -f "$renderer_pid_file" ]; then
        renderer_pid=$(cat "$renderer_pid_file" 2>/dev/null || echo "")
        if [ -n "$renderer_pid" ] && kill -0 "$renderer_pid" 2>/dev/null; then
            has_renderer=1
        else
            rm -f "$renderer_pid_file"
        fi
    fi
fi

# Build -t flag for list-panes when a target is given.
target_flag=()
if [ -n "$TARGET" ]; then
    target_flag=(-t "$TARGET")
fi

# Find sidebar pane in the target window by title.
find_sidebar_in_window() {
    tmux list-panes "${target_flag[@]}" -F '#{pane_id} #{pane_title}' 2>/dev/null | \
        while read -r pid title; do
            if [ "$title" = "$SIDEBAR_TITLE" ]; then
                echo "$pid"
                return 0
            fi
        done
}

# Find the file manager sidebar (narrow left-edge pane, not ours).
find_file_sidebar() {
    tmux list-panes "${target_flag[@]}" -F '#{pane_id} #{pane_left} #{pane_width} #{pane_title}' 2>/dev/null | \
        while read -r pid left w title; do
            if [ "$left" = "0" ] && [ "$w" -le 60 ] && [ "$title" != "$SIDEBAR_TITLE" ]; then
                echo "$pid"
                return 0
            fi
        done
}

existing=$(find_sidebar_in_window)

if [ -n "$existing" ]; then
    if [ "$MODE" = "toggle" ]; then
        tmux kill-pane -t "$existing"
        exit 0
    fi
    # Visible already, and not a toggle: focus it rather than closing.
    tmux select-pane -t "$existing"
else
    file_sidebar=$(find_file_sidebar)

    # When a renderer is already running for this session, create a display
    # proxy instead of a second renderer. The proxy reads the renderer's
    # output from a shared file and costs negligible CPU.
    if [ "$has_renderer" = "1" ]; then
        sidebar_cmd="$CURRENT_DIR/sidebar-display-proxy.sh"
    else
        sidebar_cmd="$CURRENT_DIR/sidebar.sh"
    fi

    if [ -n "$file_sidebar" ]; then
        # File manager is open — split below it (inherits the same width).
        new_pane=$(tmux split-window -v -t "$file_sidebar" \
            -PF '#{pane_id}' "$sidebar_cmd")
    else
        # No file manager — create a left-side split spanning the whole window.
        #
        # -f is what makes this the full window height. Without it the split is
        # relative to the target pane, so opening the sidebar in a window that
        # was already split top/bottom produced a sidebar as tall as whichever
        # pane happened to be leftmost, and a later split elsewhere left it
        # stranded at that height. With -f the sidebar always spans the window
        # and subsequent splits divide only the remaining area.
        leftmost=$(tmux list-panes "${target_flag[@]}" -F '#{pane_left} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
        new_pane=$(tmux split-window -fhb -l "$width" -t "$leftmost" \
            -PF '#{pane_id}' "$sidebar_cmd")
    fi

    # Tag the pane so we can find it later.
    tmux select-pane -t "$new_pane" -T "$SIDEBAR_TITLE"
fi
