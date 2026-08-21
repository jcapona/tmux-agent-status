#!/usr/bin/env bash

# Shared session-status helpers used by the sidebar, switcher, and other scripts.
# Provides: has_agent_in_session, status_priority, get_pane_status,
#           get_window_status, get_agent_status, sync_session_after_child_scope_change,
#           plus the STATUS_DIR constant.

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=require-bash4.sh
source "$_LIB_DIR/require-bash4.sh"
require_bash4 "$@"

[[ -n "${_SESSION_STATUS_LOADED:-}" ]] && return 0
_SESSION_STATUS_LOADED=1

STATUS_DIR="$HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"
SIDEBAR_CLIENT_DIR="$STATUS_DIR/sidebar-clients"
STATUS_LINE_CACHE_FILE="$STATUS_DIR/.status-line"
SIDEBAR_CACHE_FILE="$STATUS_DIR/.sidebar-cache"

# How stale the collector's cache may be before it is ignored. The collector
# rewrites it once a second while running, so anything older than this means it
# is not running and the raw files are all there is.
SIDEBAR_CACHE_MAX_AGE=30
STATUS_LINE_COUNTS_FILE="$STATUS_DIR/.status-line-counts"
REFRESH_FILE="$STATUS_DIR/.sidebar-refresh"
VISIBLE_FILE="$STATUS_DIR/.visible-panes"
mkdir -p "$STATUS_DIR" "$PANE_DIR" "$SIDEBAR_CLIENT_DIR"
[ -f "$REFRESH_FILE" ] || : > "$REFRESH_FILE"

# Source process-detection helpers from the same lib directory.
# shellcheck source=agent-processes.sh
source "$_LIB_DIR/agent-processes.sh"


has_agent_in_session() {
    session_has_agent_process "$1"
}



status_priority() {
    case "$1" in
        working) echo 5 ;;
        ask) echo 3 ;;
        done) echo 2 ;;
        *) echo 0 ;;
    esac
}

write_session_status() {
    local session="$1"
    local state="$2"
    echo "$state" > "$STATUS_DIR/${session}.status" 2>/dev/null
}

recompute_session_status() {
    local session="$1"
    local best_status="done"
    local best_priority
    best_priority=$(status_priority "$best_status")

    local pane_file=""
    for pane_file in "$PANE_DIR/${session}_"*.status; do
        [ -f "$pane_file" ] || continue

        local pane_name pane_id pane_status pane_priority
        pane_name=$(basename "$pane_file" .status)
        pane_id="${pane_name##*_}"

        pane_status=$(cat "$pane_file" 2>/dev/null || echo "")

        pane_priority=$(status_priority "$pane_status")
        if [ "$pane_priority" -gt "$best_priority" ]; then
            best_priority="$pane_priority"
            best_status="$pane_status"
        fi
    done

    write_session_status "$session" "$best_status"
}



# The state the collector resolved for a pane, or failure if it has no opinion.
#
# The collector applies rules that a one-shot caller cannot: a pane with no
# status file of its own is unknown rather than inheriting the session's, and a
# "working" claim is disbelieved once the pane's screen stops changing -- which
# needs screen hashes remembered between samples, so only a long-lived process
# can do it.
#
# Re-deriving from the raw files instead means each surface disagrees with the
# others. The switcher showed panes as working that the sidebar showed as idle,
# including panes with no status file at all.
cached_pane_status() {
    local session="$1" pane_id="$2" now mtime line
    [ -f "$SIDEBAR_CACHE_FILE" ] || return 1
    printf -v now '%(%s)T' -1
    # See collect.sh: stat -f is not portable; on Linux it writes garbage
    # to stdout before failing, so a || fallback still returns it.
    if [[ "$(uname)" == "Darwin" ]]; then
        mtime=$(stat -f %m "$SIDEBAR_CACHE_FILE" 2>/dev/null) || return 1
    else
        mtime=$(stat -c %Y "$SIDEBAR_CACHE_FILE" 2>/dev/null) || return 1
    fi
    [ -n "$mtime" ] || return 1
    (( now - mtime > SIDEBAR_CACHE_MAX_AGE )) && return 1
    line=$(grep -m1 -F "R:Q|${session}|${pane_id}|" "$SIDEBAR_CACHE_FILE" 2>/dev/null) || return 1
    [ -n "$line" ] || return 1
    line="${line#*|*|*|*|}"
    printf '%s' "${line%%|*}"
}

get_pane_status() {
    local session="$1"
    local pane_id="$2"
    local pane_status="$PANE_DIR/${session}_${pane_id}.status"

    # Prefer the collector's resolved verdict; fall back to the raw files when
    # it is not running.
    local _resolved
    if _resolved=$(cached_pane_status "$session" "$pane_id") && [ -n "$_resolved" ]; then
        printf '%s\n' "$_resolved"
        return
    fi

    if [ -f "$pane_status" ]; then
        cat "$pane_status" 2>/dev/null || echo ""
        return
    fi

    # This pane has never reported. Falling back to the session's state here is
    # the same mistake collect_data used to make: the session's state is the
    # highest-priority state among its panes, so one genuinely working agent
    # made every silent pane beside it report working too -- including panes
    # running a plain shell.
    #
    # Inherit only when the session has no per-pane data at all, which is what
    # the fallback exists for: a session whose agents have not reported per-pane
    # yet -- a Codex session detected by process scan before any hook has fired --
    # where the session-level state is the only signal there is.
    local _any
    for _any in "$PANE_DIR/${session}_"*.status; do
        if [ -f "$_any" ]; then
            echo "idle"
            return
        fi
    done

    get_agent_status "$session"
}

get_window_status() {
    local session="$1"
    local window_index="$2"
    local best_status=""
    local best_priority=0
    local pane_id=""

    while IFS= read -r pane_id; do
        [ -z "$pane_id" ] && continue

        local pane_status pane_priority
        pane_status=$(get_pane_status "$session" "$pane_id")
        pane_priority=$(status_priority "$pane_status")
        if [ "$pane_priority" -gt "$best_priority" ]; then
            best_priority="$pane_priority"
            best_status="$pane_status"
        fi
    done < <(tmux list-panes -t "${session}:${window_index}" -F "#{pane_id}" 2>/dev/null)

    if [ -n "$best_status" ]; then
        echo "$best_status"
    else
        get_agent_status "$session"
    fi
}

get_agent_status() {
    local session="$1"

    # Check local status files
    local status_file="$STATUS_DIR/${session}.status"
    if [ -f "$status_file" ]; then
        local status
        status=$(cat "$status_file" 2>/dev/null || echo "")
        printf '%s\n' "$status"
    else
        echo ""
    fi
}

