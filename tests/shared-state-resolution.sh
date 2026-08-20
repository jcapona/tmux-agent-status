#!/usr/bin/env bash
#
# Every surface must report the state the collector resolved, not re-derive it.
#
# The collector applies rules a one-shot caller cannot: a pane with no status
# file is unknown rather than inheriting the session's state, and a "working"
# claim is disbelieved once the pane's screen stops changing -- which needs
# hashes remembered between samples. Re-deriving from raw files made the
# switcher disagree with the sidebar, showing panes as working that had no
# status file at all.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export HOME="$TMP_DIR/home"
D="$HOME/.cache/tmux-agent-status"
mkdir -p "$D/panes"

FAILURES=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; FAILURES=$((FAILURES+1)); fi
}
ask() { /opt/homebrew/bin/bash -c "source '$REPO_DIR/scripts/lib/session-status.sh'; get_pane_status '$1' '$2'" 2>/dev/null; }

echo "shared-state-resolution"

# The collector says idle for a pane whose raw file says working.
printf 'working\n' > "$D/panes/0_%100.status"
printf 'R:Q|0|%%100|claude|idle|1|0\n' > "$D/.sidebar-cache"
check "the collector's verdict wins over the raw file" "idle" "$(ask 0 '%100')"

# A pane with no raw file at all still gets the collector's answer.
printf 'R:Q|0|%%200|claude|idle|1|0\n' >> "$D/.sidebar-cache"
check "a pane with no status file resolves too"        "idle" "$(ask 0 '%200')"

# Panes the collector has an opinion on are not confused with each other.
printf 'R:Q|0|%%300|claude|working|1|0\n' >> "$D/.sidebar-cache"
check "working is passed through unchanged"            "working" "$(ask 0 '%300')"

# A stale cache means no collector; fall back to the raw file rather than
# reporting a verdict from some earlier era.
touch -t 200001010000 "$D/.sidebar-cache"
check "a stale cache falls back to the raw file"       "working" "$(ask 0 '%100')"

# No cache at all behaves the same way.
rm -f "$D/.sidebar-cache"
check "no cache falls back to the raw file"            "working" "$(ask 0 '%100')"

# A pane that has never reported must not inherit the session's state -- the
# same mistake collect_data used to make, and the reason a plain shell showed as
# working next to a busy agent.
printf 'working\n' > "$D/panes/0_%400.status"     # session has per-pane data
printf 'working\n' > "$D/0.status"                # and the session says working
rm -f "$D/.sidebar-cache"
check "a never-reporting pane does not inherit"   "idle" "$(ask 0 '%500')"
check "  a reporting pane is unaffected"          "working" "$(ask 0 '%400')"

# With no per-pane data at all, inheriting is still right: that is the SSH
# remote case, where session state is the only signal.
rm -f "$D"/panes/*.status
check "sessions with no pane data still inherit"  "working" "$(ask 0 '%600')"

if [ "$FAILURES" -ne 0 ]; then printf '\n%d check(s) failed\n' "$FAILURES"; exit 1; fi
printf '\nall checks passed\n'
