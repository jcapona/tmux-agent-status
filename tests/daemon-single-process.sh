#!/usr/bin/env bash

set -euo pipefail

# Verify the three-process daemon stack has been collapsed to one.
# The collector is the single always-running process. daemon-monitor.sh
# is no longer started by the plugin. smart-monitor.sh is called as a
# one-shot `update` by the collector, not as a separate daemon.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 1. tmux-agent-status.tmux must not reference daemon-monitor.sh.
if grep -q 'daemon-monitor' "$REPO_DIR/tmux-agent-status.tmux"; then
    echo "FAIL: tmux-agent-status.tmux still references daemon-monitor.sh" >&2
    grep -n 'daemon-monitor' "$REPO_DIR/tmux-agent-status.tmux" >&2
    exit 1
fi

# 2. tmux-agent-status.tmux must start the collector on session-created.
if ! grep -q 'sidebar-collector.sh' "$REPO_DIR/tmux-agent-status.tmux"; then
    echo "FAIL: tmux-agent-status.tmux does not start sidebar-collector.sh" >&2
    exit 1
fi

# 3. hook-based-switcher.sh must not restart daemon-monitor or smart-monitor.
if grep -q 'daemon-monitor' "$REPO_DIR/scripts/hook-based-switcher.sh"; then
    echo "FAIL: hook-based-switcher.sh still references daemon-monitor.sh" >&2
    exit 1
fi

if grep -q 'smart-monitor.*start' "$REPO_DIR/scripts/hook-based-switcher.sh"; then
    echo "FAIL: hook-based-switcher.sh still starts smart-monitor as a daemon" >&2
    exit 1
fi

# 4. The collector must call smart-monitor.sh update in its liveness sweep.
if ! grep -q 'smart-monitor.*update' "$REPO_DIR/scripts/sidebar-collector.sh"; then
    echo "FAIL: collector does not call smart-monitor.sh update" >&2
    exit 1
fi

# 5. smart-monitor.sh must still exist (for SSH status polling and setup-server.sh).
if [ ! -f "$REPO_DIR/smart-monitor.sh" ]; then
    echo "FAIL: smart-monitor.sh was deleted (still needed for SSH updates)" >&2
    exit 1
fi

echo "daemon-single-process checks passed"
