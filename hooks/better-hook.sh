#!/usr/bin/env bash

# Claude Code hook for tmux-agent-status
# Updates tmux session and pane status files based on Claude's working state

STATUS_DIR="$HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"
REFRESH_FILE="$STATUS_DIR/.sidebar-refresh"
mkdir -p "$STATUS_DIR" "$PANE_DIR"
[ -f "$REFRESH_FILE" ] || : > "$REFRESH_FILE"

# Read JSON from stdin (required by Claude Code hooks). The Stop payload
# carries a `background_tasks` array that we inspect below.
HOOK_JSON="$(cat 2>/dev/null || true)"

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
        echo "claude" > "$agent_file"

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

# Returns 0 if the Claude Code Stop payload reports a background task that is
# still running (e.g. a `run_in_background` Bash command). When the agent ends
# its turn while a background task keeps working, it isn't really idle, so we
# keep it "working" instead of flipping to "done". Claude re-invokes the agent
# when the task finishes, firing another Stop with an empty (or all-finished)
# background_tasks array, which then marks the session done.
#
# Older Claude versions omit the field entirely; that yields no match and the
# Stop is treated as done, matching the previous behaviour.
has_running_background_task() {
    local json="$1"
    [ -n "$json" ] || return 1

    if command -v jq >/dev/null 2>&1; then
        local count
        count="$(printf '%s' "$json" | \
            jq -r '[.background_tasks[]? | select(.status == "running")] | length' \
            2>/dev/null)"
        [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null
        return
    fi

    # Fallback without jq: an empty array is "background_tasks":[] and is
    # rejected first; otherwise look for a running task in a populated array.
    case "$json" in
        *'"background_tasks":[]'*) return 1 ;;
        *'"background_tasks":['*'"status":"running"'*) return 0 ;;
        *) return 1 ;;
    esac
}

TMUX_SESSION=$(get_tmux_session) || exit 0
HOOK_TYPE="${1:-}"

case "$HOOK_TYPE" in
    UserPromptSubmit)
        # User submitted a prompt — an explicit interaction.
        set_status "$TMUX_SESSION" "working"
        mark_refresh
        ;;
    PreToolUse)
        # Agent is calling a tool.
            set_status "$TMUX_SESSION" "working"
        mark_refresh
        ;;
    Stop)
        # Claude has finished responding (SubagentStop excluded - subagents
        # finishing doesn't mean the main agent is done). If the turn ended
        # while a background task is still running, the agent isn't idle yet —
        # keep it working until a later Stop reports the task finished.
        if has_running_background_task "$HOOK_JSON"; then
            set_status "$TMUX_SESSION" "working"
        else
            set_status "$TMUX_SESSION" "done"
        fi
        mark_refresh
        ;;
    Notification)
        # Claude is waiting for user input.
        set_status "$TMUX_SESSION" "done"
        mark_refresh

        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        "$SCRIPT_DIR/../scripts/play-sound.sh" 2>/dev/null &
        ;;
esac

# Always exit successfully
exit 0
