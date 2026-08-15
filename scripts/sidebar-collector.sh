#!/usr/bin/env bash

# Sidebar data collector daemon.
# One instance per tmux server. Sources lib/collect.sh for data collection
# and writes a cache file that all sidebar renderers read from.
#
# Uses filesystem event notification (fswatch or inotifywait) when available
# for event-driven collection — zero work when no status files change. Falls
# back to 1s polling when neither tool is installed. A periodic liveness
# sweep runs every 30s to catch process exits that don't touch files.

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

# Run one collection cycle: collect, and if data changed, serialize + publish + signal.
run_collect_cycle() {
    tmux list-sessions >/dev/null 2>&1 || exit 0
    collect_data
    if (( _COLLECT_CHANGED )); then
        serialize_cache
        publish_status_summary
        signal_sidebar_clients USR1 all
    fi
}

# ─── --once mode: collect a single snapshot and exit ──────────────
if (( RUN_ONCE )); then
    tmux list-sessions >/dev/null 2>&1 || exit 0
    collect_data
    if (( _COLLECT_CHANGED )); then
        serialize_cache
        publish_status_summary
    fi
    exit 0
fi

# ─── Normal mode: event-driven collection ─────────────────────────
LIVENESS_INTERVAL=30  # seconds between forced liveness sweeps

# Determine which filesystem watcher to use, if any.
if command -v fswatch >/dev/null 2>&1; then
    # fswatch: cross-platform (FSEvents on macOS, inotify on Linux).
    # -l 1: batch events with 1-second latency (reduces noise from rapid writes).
    # -r:  watch recursively so panes/, wait/, parked/ are all covered.
    WATCHER="fswatch"
elif command -v inotifywait >/dev/null 2>&1; then
    # inotifywait: Linux only, from inotify-tools.
    # -m:  monitor mode (don't exit after first event).
    # -q:  quiet (don't print event descriptions).
    # -e:  which events to watch.
    WATCHER="inotifywait"
else
    WATCHER=""
fi

if [ -n "$WATCHER" ]; then
    if [ "$WATCHER" = "fswatch" ]; then
        exec 3< <(fswatch -l 1 -r "$STATUS_DIR" 2>/dev/null)
    else
        exec 3< <(inotifywait -m -q -e modify,create,delete,move \
            "$STATUS_DIR" "$PANE_DIR" "$WAIT_DIR" "$PARKED_DIR" 2>/dev/null)
    fi

    while true; do
        if read -t "$LIVENESS_INTERVAL" -r _ <&3; then
            # Filesystem event — collect and signal if changed.
            run_collect_cycle
        else
            # Read timeout — run a forced liveness sweep to catch process
            # exits and wait-timer expirations that don't touch files.
            _LAST_STATUS_MTIME=""
            run_collect_cycle
        fi
    done
else
    # Fallback: 1s polling. Still event-driven in practice because collect_data
    # has its own mtime-based change detection — the 1s sleep is just the poll
    # interval. The liveness sweep is implicit: every collect_data call does
    # ps + tmux list-panes when the mtime changes, and expire_wait_timers runs
    # on every call.
    echo "tmux-agent-status: fswatch/inotifywait not found, falling back to 1s polling" >&2

    while true; do
        run_collect_cycle
        sleep 1
    done
fi
