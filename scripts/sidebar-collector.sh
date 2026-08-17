#!/usr/bin/env bash

# Sidebar data collector daemon.
# One instance per tmux server. Sources lib/collect.sh for data collection
# and writes a cache file that all sidebar renderers read from.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/session-status.sh"
source "$SCRIPT_DIR/lib/collect.sh"
source "$SCRIPT_DIR/lib/status-summary.sh"
source "$SCRIPT_DIR/lib/sidebar-clients.sh"

CACHE_FILE="$STATUS_DIR/.sidebar-cache"
PID_FILE="$STATUS_DIR/.sidebar-collector.pid"
RUN_ONCE=0

if [[ "${1:-}" == "--once" ]]; then
    RUN_ONCE=1
fi

# Singleton guard.
#
# The previous check-then-write test let two collectors start together: each
# read a missing or stale PID file, each concluded no collector was running,
# and each wrote its own PID. The second overwrote the first, so the first's
# EXIT trap then deleted a PID file naming the second. Observed repeatedly as
# two live collectors after a config reload, doubling the daemon's cost.
#
# mkdir is atomic: exactly one process can create a given directory, so the
# claim and the check are a single indivisible step.
LOCK_DIR="$STATUS_DIR/.sidebar-collector.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        exit 0
    fi
    # Lock exists but its owner is gone -- killed, crashed, or the machine
    # rebooted with the lock on disk. Reclaim it; if another process wins that
    # same race, defer to it rather than running a second collector.
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || exit 0
fi
echo $$ > "$PID_FILE"
trap 'rm -rf "$LOCK_DIR"; rm -f "$PID_FILE"' EXIT

# Persistent cross-cycle state (survives across collect_data calls)
declare -A KNOWN_AGENTS=()
declare -A LIVE_PANES=()
declare -A PID_PPID=()
declare -A PANE_COUNTS=()
ENTRIES=()
SEL_NAMES=()
SEL_TYPES=()
SESS_START=0
_COLLECT_TICK=0
_LAST_STATUS_MTIME=""
_COLLECT_CHANGED=0
SUMMARY_WORKING=0
SUMMARY_WAITING=0
SUMMARY_DONE=0
SUMMARY_TOTAL=0
SUMMARY_HAS_WORKING=0
SUMMARY_AGENTS=()

_tab=$'\t'

serialize_cache() {
    {
        echo "TS:$(date +%s)"
        echo "SESS_START:$SESS_START"
        for sname in "${!PANE_COUNTS[@]}"; do
            echo "PC:${sname}:${PANE_COUNTS[$sname]}"
        done
        local si=0
        for entry in "${ENTRIES[@]}"; do
            local etype="${entry%%|*}"
            if [[ "$etype" == "G" ]]; then
                echo "E:${entry}"
            else
                printf 'R:%s\t%s\t%s\n' "$entry" "${SEL_NAMES[$si]}" "${SEL_TYPES[$si]}"
                ((si++))
            fi
        done
    } > "${CACHE_FILE}.tmp"
    mv -f "${CACHE_FILE}.tmp" "$CACHE_FILE"
}

publish_status_summary() {
    local prev_done=""

    if [ -f "$STATUS_LINE_COUNTS_FILE" ]; then
        IFS=: read -r _ _ prev_done _ < "$STATUS_LINE_COUNTS_FILE"
    fi

    write_status_summary_cache \
        "$SUMMARY_WORKING" \
        "$SUMMARY_WAITING" \
        "$SUMMARY_DONE" \
        "$SUMMARY_TOTAL" \
        "${SUMMARY_AGENTS[@]}"

    if (( ! RUN_ONCE )) && [ -n "$prev_done" ] && [ "$SUMMARY_DONE" -gt "$prev_done" ]; then
        "$SCRIPT_DIR/play-sound.sh" &
    fi
}

tick=0
while true; do
    tmux list-sessions >/dev/null 2>&1 || exit 0

    if (( tick == 0 )); then
        collect_data
        if (( _COLLECT_CHANGED )); then
            serialize_cache
            publish_status_summary
            (( ! RUN_ONCE )) && signal_sidebar_clients USR1 all
        fi
    fi

    if (( RUN_ONCE )); then
        exit 0
    fi

    if (( SUMMARY_HAS_WORKING )); then
        signal_sidebar_clients USR2 active
    fi

    sleep 0.25
    tick=$(( (tick + 1) % 4 ))
done
