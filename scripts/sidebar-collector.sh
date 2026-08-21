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
# Claim ownership with a hard link.
#
# Every two-step claim has a window: mkdir-then-write-PID, or create-then-write,
# both leave an instant where the lock exists but names no owner. A loser that
# looks during that instant sees an ownerless lock, concludes the owner is dead,
# and takes over -- which is how ten simultaneous starts produced two, and then
# nine, collectors while the guard "looked" atomic.
#
# ln is atomic and fails if the target exists, and the file it links already
# contains our PID. The lock therefore never exists without naming its owner.
_claim() {
    local staging="$PID_FILE.$$"
    echo $$ > "$staging" || return 1
    if ln "$staging" "$PID_FILE" 2>/dev/null; then
        rm -f "$staging"
        return 0
    fi
    rm -f "$staging"
    return 1
}

if ! _claim; then
    owner=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        exit 0
    fi
    # Owner is gone: killed, crashed, or left behind by a reboot. Clear the
    # stale claim and try once; losing that race means someone else got there
    # first, which is the outcome we want anyway.
    rm -f "$PID_FILE"
    _claim || exit 0
fi
trap 'rm -f "$PID_FILE"' EXIT

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
        IFS=: read -r _ prev_done _ < "$STATUS_LINE_COUNTS_FILE"
    fi

    write_status_summary_cache \
        "$SUMMARY_WORKING" \
        "$SUMMARY_DONE" \
        "$SUMMARY_TOTAL" \
        "${SUMMARY_AGENTS[@]}"

    if (( ! RUN_ONCE )) && [ -n "$prev_done" ] && [ "$SUMMARY_DONE" -gt "$prev_done" ]; then
        "$SCRIPT_DIR/play-sound.sh" &
    fi
}

tick=0
while true; do
    # Liveness, once a second rather than on every 0.25s tick. This is a full
    # tmux IPC round trip -- measured at 6ms on a server with 15 sessions, so
    # four a second was 24ms/s, about a third of everything the collector spent.
    # Noticing a dead server three quarters of a second later costs nothing: the
    # collector exits either way, and nothing depends on how promptly.
    if (( tick == 0 )); then
        tmux list-sessions >/dev/null 2>&1 || exit 0

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
