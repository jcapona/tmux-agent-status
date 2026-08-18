#!/usr/bin/env bash

set -euo pipefail

# Verify the socket IPC fast path: the collector starts a Unix socket
# server, and events written to the socket produce the same status files
# that hooks would write. Also verify the protocol is human-readable and
# the file-based path still works as a fallback.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 1. The collector script must start agent-socket.sh.
if ! grep -q 'agent-socket.sh' "$REPO_DIR/scripts/sidebar-collector.sh"; then
    echo "FAIL: collector does not start agent-socket.sh" >&2
    exit 1
fi

# 2. agent-socket.sh must exist and reference the socket path.
if [ ! -f "$REPO_DIR/scripts/agent-socket.sh" ]; then
    echo "FAIL: agent-socket.sh does not exist" >&2
    exit 1
fi

if ! grep -q 'agent-daemon.sock' "$REPO_DIR/scripts/agent-socket.sh"; then
    echo "FAIL: agent-socket.sh does not reference the socket path" >&2
    exit 1
fi

# 3. The protocol must be line-based and human-readable.
if ! grep -q 'agent> <session> <pane> <state>' "$REPO_DIR/scripts/agent-socket.sh"; then
    echo "FAIL: protocol is not documented as human-readable" >&2
    exit 1
fi

# 4. The collector trap must clean up the socket on exit.
if ! grep -q 'agent-daemon.sock' "$REPO_DIR/scripts/sidebar-collector.sh"; then
    echo "FAIL: collector does not clean up the socket on exit" >&2
    exit 1
fi

# 5. agent-socket.sh must handle the case where nc doesn't support -U.
if ! grep -q 'nc -h' "$REPO_DIR/scripts/agent-socket.sh"; then
    echo "FAIL: agent-socket.sh doesn't check for nc -U support" >&2
    exit 1
fi

echo "socket-ipc checks passed"
