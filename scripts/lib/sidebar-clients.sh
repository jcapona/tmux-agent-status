#!/usr/bin/env bash

[[ -n "${_SIDEBAR_CLIENTS_LOADED:-}" ]] && return 0
_SIDEBAR_CLIENTS_LOADED=1

SIDEBAR_TITLE="${SIDEBAR_TITLE:-agent-sidebar}"

register_sidebar_client() {
    local pane_id="${1:-}"
    [ -n "$pane_id" ] || pane_id="$(tmux display-message -p '#{pane_id}' 2>/dev/null)"
    [ -n "$pane_id" ] || return 1

    mkdir -p "$SIDEBAR_CLIENT_DIR"
    printf '%s\n' "$$" > "$SIDEBAR_CLIENT_DIR/${pane_id}.pid"
    printf '%s\n' "$pane_id"
}

unregister_sidebar_client() {
    local pane_id="$1"
    [ -n "$pane_id" ] || return 0
    rm -f "$SIDEBAR_CLIENT_DIR/${pane_id}.pid"
}

# ─── Pane info cache ─────────────────────────────────────────────
# signal_sidebar_clients used to call tmux list-panes -a on every invocation
# to validate which panes are still sidebars. With N sidebar clients that is
# N IPC calls per signal, and the collector signals on every state change.
# The cache refreshes at most every 5 seconds; between refreshes the signal
# path is just kill -s over PID files — zero tmux IPC.
_PANE_CACHE_TS=0
declare -A _PANE_CACHE_TITLES=()
declare -A _PANE_CACHE_ACTIVE=()

_refresh_pane_cache() {
    local now
    printf -v now '%(%s)T' -1
    (( now - _PANE_CACHE_TS < 5 )) && return 0
    _PANE_CACHE_TS=$now
    _PANE_CACHE_TITLES=()
    _PANE_CACHE_ACTIVE=()

    local pane_id pane_title pane_is_active
    while IFS=$'\t' read -r pane_id pane_title pane_is_active; do
        [ -n "$pane_id" ] || continue
        _PANE_CACHE_TITLES[$pane_id]="$pane_title"
        _PANE_CACHE_ACTIVE[$pane_id]="${pane_is_active:-0}"
    done < <(tmux list-panes -a -F '#{pane_id}'$'\t''#{pane_title}'$'\t''#{pane_active}' 2>/dev/null)
}

signal_sidebar_clients() {
    local signal_name="$1"
    local scope="${2:-all}"
    local pane_file pane_id pid

    for pane_file in "$SIDEBAR_CLIENT_DIR/"*.pid; do
        [ -f "$pane_file" ] || return 0
        break
    done

    _refresh_pane_cache

    for pane_file in "$SIDEBAR_CLIENT_DIR/"*.pid; do
        [ -f "$pane_file" ] || continue

        # Parameter expansion and $(<file), not basename and cat: both of those
        # fork a subshell, and this loop runs four times a second per client to
        # drive the spinner. Two forks per client per tick is the kind of cost
        # that does not show up in any one place and adds up to a percent.
        pane_id="${pane_file##*/}"
        pane_id="${pane_id%.pid}"
        pid="$(<"$pane_file")" 2>/dev/null || pid=""

        if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$pane_file"
            continue
        fi

        if [ "${_PANE_CACHE_TITLES[$pane_id]:-}" != "$SIDEBAR_TITLE" ]; then
            rm -f "$pane_file"
            continue
        fi

        if [ "$scope" = "active" ] && [ "${_PANE_CACHE_ACTIVE[$pane_id]:-0}" != "1" ]; then
            continue
        fi

        kill -s "$signal_name" "$pid" 2>/dev/null || rm -f "$pane_file"
    done
}
