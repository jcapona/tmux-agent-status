#!/usr/bin/env bash

set -euo pipefail

# Verify signal_sidebar_clients caches the tmux list-panes -a call.
# Calling it multiple times within 5 seconds should invoke tmux at
# most once. The signal path must be just kill -s over PID files.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
TMUX_CALL_LOG="$TMP_DIR/tmux_calls.log"

mkdir -p "$FAKE_BIN" "$STATUS_DIR/sidebar-clients"

# Fake tmux that logs every invocation and returns two sidebar panes.
cat > "$FAKE_BIN/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "call" >> "$TMUX_CALL_LOG"
case "\${1:-}" in
    list-panes)
        printf '%%1\tagent-sidebar\t1\n'
        printf '%%2\tagent-sidebar\t0\n'
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

# Spawn a dummy listener to receive signals.
bash -c 'trap "true" USR1; while :; do sleep 1; done' >/dev/null 2>&1 &
listener_pid=$!
trap 'kill "$listener_pid" 2>/dev/null' EXIT
printf '%s\n' "$listener_pid" > "$STATUS_DIR/sidebar-clients/%1.pid"

sleep 0.2

# Call signal_sidebar_clients 10 times in quick succession.
# The libs need Bash 4+; macOS /bin/bash is 3.2, so pick the same interpreter
# the plugin's own require-bash4 guard would, rather than whatever is on PATH.
BASH_BIN="$(command -v bash)"
for c in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$c" ] && BASH_BIN="$c" && break
done
PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" "$BASH_BIN" -c '
    source "'"${REPO_DIR}"'/scripts/lib/session-status.sh"
    source "'"${REPO_DIR}"'/scripts/lib/sidebar-clients.sh"
    for i in $(seq 1 10); do
        signal_sidebar_clients USR1 all
    done
'

sleep 0.3

# Count tmux calls. The first call populates the cache; subsequent
# calls within 5 seconds should use the cache and not call tmux.
call_count=$(wc -l < "$TMUX_CALL_LOG" 2>/dev/null || echo 0)

if [ "$call_count" -gt 1 ]; then
    echo "FAIL: tmux called $call_count times for 10 signal calls (expected at most 1)" >&2
    cat "$TMUX_CALL_LOG" >&2
    exit 1
fi

echo "sidebar-signal-no-ipc checks passed (tmux called $call_count time(s) for 10 signal calls)"
