#!/usr/bin/env bash

# Display proxy for the agent sidebar.
#
# When @agent-sidebar-per-window is "on", only one window per session runs
# the full sidebar.sh renderer. Every other window runs this proxy, which
# reads the renderer's output from a shared file and writes it to its pane.
# The proxy has no event loop, no tmux IPC, no associative arrays — it is a
# simple poll-and-display loop that costs negligible CPU.
#
# Interactive input (keyboard, mouse) is not forwarded to the renderer in
# this version. To interact with the sidebar, switch to the window that
# holds the renderer (the one where prefix+O first opened it).
#
# Usage: sidebar-display-proxy.sh <session-name>

SESSION_NAME="${1:-}"

STATUS_DIR="$HOME/.cache/tmux-agent-status"
SIDEBAR_TITLE="agent-sidebar"

# Terminal setup: hide cursor, disable echo.
tput civis 2>/dev/null
stty -echo 2>/dev/null

cleanup() {
    tput cnorm 2>/dev/null
    stty echo 2>/dev/null
}
trap cleanup EXIT
trap 'exit 0' INT TERM HUP

# Exit if our pane/TTY is gone.
[[ ! -t 0 ]] && exit 0

SELF_PANE="${TMUX_PANE:-}"
if [ -z "$SELF_PANE" ]; then
    SELF_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)
fi

# Resolve the session name from the pane, which is more reliable than
# display-message without a target (that returns the client's session,
# not necessarily the pane's).
if [ -z "$SESSION_NAME" ] && [ -n "$SELF_PANE" ]; then
    SESSION_NAME=$(tmux display-message -t "$SELF_PANE" -p '#{session_name}' 2>/dev/null || echo "")
fi
if [ -z "$SESSION_NAME" ]; then
    SESSION_NAME=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")
fi
[ -n "$SESSION_NAME" ] || exit 0

RENDER_FILE="$STATUS_DIR/.sidebar-render.$SESSION_NAME"

if [ -n "$SELF_PANE" ]; then
    tmux select-pane -t "$SELF_PANE" -T "$SIDEBAR_TITLE" >/dev/null 2>&1 || true
fi

last_mtime=0

while true; do
    # Exit if our pane is gone.
    [[ ! -t 0 ]] && exit 0

    # Check render file mtime; re-display only when it changed.
    if [[ "$(uname)" == "Darwin" ]]; then
        current_mtime=$(stat -f %m "$RENDER_FILE" 2>/dev/null || echo 0)
    else
        current_mtime=$(stat -c %Y "$RENDER_FILE" 2>/dev/null || echo 0)
    fi

    if [ "$current_mtime" != "$last_mtime" ] && [ -f "$RENDER_FILE" ]; then
        last_mtime="$current_mtime"
        # Replay the renderer's output: clear screen, then write the frame.
        printf '\033[2J\033[H'
        cat "$RENDER_FILE"
    fi

    sleep 1
done
