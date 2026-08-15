#!/usr/bin/env bash

# Unix domain socket server for fast-path agent events.
#
# Started as a child process of sidebar-collector.sh. Listens on
# $STATUS_DIR/agent-daemon.sock and processes one-line events:
#
#   <agent> <session> <pane> <state>
#
# Writes the state to the same status files that hooks write, so the
# collector's filesystem watcher picks it up either way. The socket is
# an optional fast path — hooks that do not use it continue to write
# status files directly, which is the default.
#
# If nc does not support Unix sockets (-U), exits silently.
#
# Protocol:
#   Events in:  one line per connection: "<agent> <session> <pane> <state>"
#               pane may be "-" for session-level events
#   Subscribers: connect and send "SUB <pane_id>"
#               the server currently does not push frames — subscriber
#               notification is handled by the collector's USR1 signal
#               and the shared render file (Phase 2)

STATUS_DIR="$HOME/.cache/tmux-agent-status"
SOCKET="$STATUS_DIR/agent-daemon.sock"
PANE_DIR="$STATUS_DIR/panes"
WAIT_DIR="$STATUS_DIR/wait"
PARKED_DIR="$STATUS_DIR/parked"

mkdir -p "$STATUS_DIR" "$PANE_DIR" "$WAIT_DIR" "$PARKED_DIR"

# Check if nc supports Unix sockets.
if ! nc -h 2>&1 | grep -q -- '-U'; then
    exit 0
fi

process_event() {
    local line="$1"
    # Parse: <agent> <session> <pane> <state>
    local agent session pane state
    read -r agent session pane state <<< "$line"
    [ -n "$agent" ] && [ -n "$session" ] && [ -n "$state" ] || return 0

    if [ -n "$pane" ] && [ "$pane" != "-" ]; then
        echo "$state" > "$PANE_DIR/${session}_${pane}.status"
        echo "$agent" > "$PANE_DIR/${session}_${pane}.agent"
    fi

    # Recompute session-level status from pane statuses (same logic as hooks).
    local session_status="done"
    local pf
    for pf in "$PANE_DIR/${session}_"*.status; do
        [ -f "$pf" ] || continue
        local ps
        ps=$(cat "$pf" 2>/dev/null || echo "")
        case "$ps" in
            working) session_status="working"; break ;;
            wait)    [ "$session_status" != "working" ] && session_status="wait" ;;
        esac
    done
    echo "$session_status" > "$STATUS_DIR/${session}.status"
}

rm -f "$SOCKET"

while true; do
    # nc -U -l creates the socket, accepts one connection, reads until
    # the client disconnects, then exits. Loop to accept the next one.
    rm -f "$SOCKET"

    # Read lines from the connection and process each as an event.
    while IFS= read -r line; do
        process_event "$line"
    done < <(nc -U -l "$SOCKET" 2>/dev/null)

    # Small delay to prevent a tight loop if nc fails immediately
    # (e.g., socket directory removed).
    sleep 0.1
done 2>/dev/null

rm -f "$SOCKET"
