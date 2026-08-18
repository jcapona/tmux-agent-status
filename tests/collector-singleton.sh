#!/usr/bin/env bash
#
# The collector must be a singleton even when several start at the same moment.
# The old check-then-write guard let concurrent starts all pass, which showed up
# as two live collectors after a config reload — double the daemon's cost.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
# Collectors run as "$REPO_DIR/scripts/sidebar-collector.sh", so a pkill on
# TMP_DIR never matched them and every run leaked its collectors into the next
# one's process count -- which looked exactly like a flaky singleton guard.
cleanup() {
    pkill -f "$REPO_DIR/scripts/sidebar-collector.sh" 2>/dev/null || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$HOME/.cache/tmux-agent-status"
mkdir -p "$FAKE_BIN" "$STATUS_DIR"

# tmux stub: enough for the collector to start and find nothing to do.
cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions) echo "solo" ;;
    list-panes)    ;;
    show-option)   ;;
    display-message) echo "" ;;
    *)             ;;
esac
exit 0
EOF
chmod +x "$FAKE_BIN/tmux"
export PATH="$FAKE_BIN:$PATH"

FAILURES=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; FAILURES=$((FAILURES+1)); fi
}

running() { pgrep -f "$REPO_DIR/scripts/sidebar-collector.sh" | wc -l | tr -d ' '; }

pkill -f "$REPO_DIR/scripts/sidebar-collector.sh" 2>/dev/null || true
sleep 1

echo "collector-singleton"

# ── ten genuinely simultaneous starts must yield one collector ─────
# Spawning in a loop is not enough: each start is milliseconds after the last,
# which is long enough for the old check-then-write guard to look correct. The
# barrier holds every process in a spin until one file appears, so they enter
# the guard within microseconds of each other -- which is what the race needs.
BARRIER="$TMP_DIR/go"
for _ in $(seq 1 10); do
    (
        while [ ! -f "$BARRIER" ]; do :; done
        exec "$REPO_DIR/scripts/sidebar-collector.sh" >/dev/null 2>&1
    ) &
done
sleep 0.5   # let every child reach the spin
: > "$BARRIER"
sleep 3
check "10 concurrent starts -> 1 collector" "1" "$(running)"

# ── a later start defers to the running one ────────────────────────
"$REPO_DIR/scripts/sidebar-collector.sh" >/dev/null 2>&1 &
sleep 2
check "a later start does not add a second" "1" "$(running)"

# ── a stale lock (owner gone) is reclaimed, not honoured forever ───
pkill -f "$REPO_DIR/scripts/sidebar-collector.sh" 2>/dev/null || true
sleep 1
echo "999999" > "$STATUS_DIR/.sidebar-collector.pid"   # a PID that cannot be alive
"$REPO_DIR/scripts/sidebar-collector.sh" >/dev/null 2>&1 &
sleep 3
check "stale lock is reclaimed"             "1" "$(running)"

# ── exiting releases the lock so the next start succeeds ───────────
pkill -f "$REPO_DIR/scripts/sidebar-collector.sh" 2>/dev/null || true
sleep 1
check "claim released on exit"              "absent" \
      "$([ -f "$STATUS_DIR/.sidebar-collector.pid" ] && echo present || echo absent)"

if [ "$FAILURES" -ne 0 ]; then
    printf '\n%d check(s) failed\n' "$FAILURES"
    exit 1
fi
printf '\nall checks passed\n'
