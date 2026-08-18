#!/usr/bin/env bash

set -euo pipefail

# Verify that sidebar-toggle.sh creates a display proxy (not a full
# renderer) when a renderer is already running for the session, and
# that the renderer PID file is managed correctly.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"

mkdir -p "$FAKE_BIN" "$STATUS_DIR"

# Fake tmux that simulates a session with one window, no sidebar yet.
# Tracks split-window calls to see what was created.
SPLIT_LOG="$TMP_DIR/splits.log"
SIDEBAR_PID=""

cat > "$FAKE_BIN/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
    show-option)
        case "\${3:-}" in
            @agent-sidebar-width) echo "42" ;;
            @agent-sidebar-per-window) echo "on" ;;
            *) echo "" ;;
        esac
        ;;
    display-message)
        # -t <target> -p '#{session_name}' -> session name
        # -p '#{session_name}' -> session name
        # -p '#{pane_id}' -> pane id
        case "\${2:-}" in
            -t)
                case "\${4:-}" in
                    '#{session_name}') echo "testsession" ;;
                    *) echo "" ;;
                esac
                ;;
            -p)
                case "\${3:-}" in
                    '#{session_name}') echo "testsession" ;;
                    '#{pane_id}') echo "%5" ;;
                    *) echo "" ;;
                esac
                ;;
        esac
        ;;
    list-panes)
        # No sidebar panes exist yet
        exit 0
        ;;
    split-window)
        echo "split-window: \$*" >> "$SPLIT_LOG"
        # Return a fake pane ID
        echo "%10"
        ;;
    select-pane)
        # Record the pane title being set
        exit 0
        ;;
    kill-pane)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

# --- Test 1: No renderer exists -> create full renderer ---
rm -f "$STATUS_DIR/.sidebar-renderer.testsession.pid" "$SPLIT_LOG"

PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" \
    "$REPO_DIR/scripts/sidebar-toggle.sh" --toggle

if ! grep -q 'sidebar\.sh' "$SPLIT_LOG"; then
    echo "FAIL: should create sidebar.sh when no renderer exists" >&2
    cat "$SPLIT_LOG" >&2
    exit 1
fi
if grep -q 'sidebar-display-proxy\.sh' "$SPLIT_LOG"; then
    echo "FAIL: should not create proxy when no renderer exists" >&2
    cat "$SPLIT_LOG" >&2
    exit 1
fi

# --- Test 2: Renderer exists -> create display proxy ---
# Simulate a running renderer by writing a PID file with a live PID.
sleep 60 &
renderer_pid=$!
trap 'kill "$renderer_pid" 2>/dev/null || true; rm -rf "$TMP_DIR"' EXIT
echo "$renderer_pid" > "$STATUS_DIR/.sidebar-renderer.testsession.pid"

rm -f "$SPLIT_LOG"

PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" \
    "$REPO_DIR/scripts/sidebar-toggle.sh" --toggle

if ! grep -q 'sidebar-display-proxy\.sh' "$SPLIT_LOG"; then
    echo "FAIL: should create proxy when renderer exists" >&2
    cat "$SPLIT_LOG" >&2
    exit 1
fi
if grep -q 'sidebar\.sh' "$SPLIT_LOG" && ! grep -q 'sidebar-display-proxy\.sh' "$SPLIT_LOG"; then
    echo "FAIL: should not create full renderer when renderer exists" >&2
    cat "$SPLIT_LOG" >&2
    exit 1
fi

# --- Test 3: Stale renderer PID -> create full renderer ---
kill "$renderer_pid" 2>/dev/null || true
# PID file still exists but process is dead
rm -f "$SPLIT_LOG"

PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" \
    "$REPO_DIR/scripts/sidebar-toggle.sh" --toggle

if ! grep -q 'sidebar\.sh' "$SPLIT_LOG"; then
    echo "FAIL: should create sidebar.sh when renderer PID is stale" >&2
    cat "$SPLIT_LOG" >&2
    exit 1
fi

# Verify stale PID file was cleaned up
if [ -f "$STATUS_DIR/.sidebar-renderer.testsession.pid" ]; then
    echo "FAIL: stale renderer PID file should have been removed" >&2
    exit 1
fi

echo "sidebar-single-renderer checks passed"
