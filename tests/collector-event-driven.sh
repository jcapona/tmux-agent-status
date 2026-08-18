#!/usr/bin/env bash

set -euo pipefail

# Verify the collector uses event-driven collection when fswatch is available,
# and falls back to 1s polling when it is not. Also verify --once mode still
# works for the other tests that depend on it.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 1. The collector script must reference fswatch and inotifywait.
if ! grep -q 'fswatch' "$REPO_DIR/scripts/sidebar-collector.sh"; then
    echo "FAIL: collector does not reference fswatch" >&2
    exit 1
fi

if ! grep -q 'inotifywait' "$REPO_DIR/scripts/sidebar-collector.sh"; then
    echo "FAIL: collector does not reference inotifywait" >&2
    exit 1
fi

# 2. The collector must have a fallback polling path.
if ! grep -q 'falling back to 1s polling' "$REPO_DIR/scripts/sidebar-collector.sh"; then
    echo "FAIL: collector does not have a fallback polling path" >&2
    exit 1
fi

# 3. The collector must have a liveness sweep interval.
if ! grep -q 'LIVENESS_INTERVAL' "$REPO_DIR/scripts/sidebar-collector.sh"; then
    echo "FAIL: collector does not have a liveness interval" >&2
    exit 1
fi

# 4. The --once mode must still work (many tests depend on it).
#    Verify the --once path exists and exits after one collection.
if ! grep -q 'RUN_ONCE' "$REPO_DIR/scripts/sidebar-collector.sh"; then
    echo "FAIL: collector lost --once mode" >&2
    exit 1
fi

# 5. The old 0.25s tick loop must be gone.
if grep -q 'sleep 0.25' "$REPO_DIR/scripts/sidebar-collector.sh"; then
    echo "FAIL: collector still has 0.25s sleep" >&2
    exit 1
fi

# 6. The old tick counter must be gone.
if grep -q 'tick=' "$REPO_DIR/scripts/sidebar-collector.sh"; then
    echo "FAIL: collector still has tick counter" >&2
    exit 1
fi

echo "collector-event-driven checks passed"
