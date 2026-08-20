#!/usr/bin/env bash

# Codex hook for tmux-agent-status.
# Hook events are passed as the first argument by the configured Codex command
# hook. The JSON payload is read from stdin and ignored here because
# tmux-agent-status only needs the event name to update session state.

STATUS_DIR="$HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"
REFRESH_FILE="$STATUS_DIR/.sidebar-refresh"
mkdir -p "$STATUS_DIR" "$PANE_DIR"
[ -f "$REFRESH_FILE" ] || : > "$REFRESH_FILE"

# Drain the JSON payload from stdin so Codex can close the hook cleanly.
cat >/dev/null 2>&1 || true

get_tmux_session() {
    local tmux_session=""

    if [ -n "${TMUX:-}" ]; then
        tmux_session=$(tmux display-message -p '#{session_name}' 2>/dev/null)

        if [ -z "$tmux_session" ]; then
            if [ -n "${TMUX:-}" ]; then
                local socket_path="${TMUX%%,*}"
                tmux_session=$(basename "$socket_path")
            fi
        fi
    fi

    [ -n "$tmux_session" ] || return 1
    printf '%s\n' "$tmux_session"
}

set_status() {
    local tmux_session="$1"
    local requested_status="$2"
    local session_status="$requested_status"
    local status_file="$STATUS_DIR/${tmux_session}.status"

    if [ -n "${TMUX_PANE:-}" ]; then
        local pane_file="$PANE_DIR/${tmux_session}_${TMUX_PANE}.status"
        local agent_file="$PANE_DIR/${tmux_session}_${TMUX_PANE}.agent"
        echo "$requested_status" > "$pane_file"
        echo "codex" > "$agent_file"

        session_status="done"
        local existing_pane_file=""
        for existing_pane_file in "$PANE_DIR/${tmux_session}_"*.status; do
            [ -f "$existing_pane_file" ] || continue

            local pane_status=""
            pane_status=$(cat "$existing_pane_file" 2>/dev/null || echo "")
            case "$pane_status" in
                working)
                    session_status="working"
                    break
                    ;;
            esac
        done
    fi

    echo "$session_status" > "$status_file"
}

mark_refresh() {
    touch "$REFRESH_FILE" 2>/dev/null || true
}

TMUX_SESSION=$(get_tmux_session) || exit 0
HOOK_TYPE="${1:-}"

case "$HOOK_TYPE" in
    SessionStart)
        set_status "$TMUX_SESSION" "done"
        mark_refresh
        ;;
    UserPromptSubmit)
        set_status "$TMUX_SESSION" "working"
        mark_refresh
        ;;
    PreToolUse|PostToolUse)
            set_status "$TMUX_SESSION" "working"
        mark_refresh
        ;;
    Stop)
        set_status "$TMUX_SESSION" "done"
        mark_refresh
        ;;
esac

exit 0
