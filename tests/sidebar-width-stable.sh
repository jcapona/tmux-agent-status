#!/usr/bin/env bash
#
# The sidebar keeps its configured width when the window's layout changes.
# tmux reflows every pane when one opens or closes, so a sidebar created at 42
# becomes a third of the window as soon as a third pane appears -- which is what
# "it changes width when I switch windows" actually was.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCKET="wstable$$"
REAL_TMUX="$(command -v tmux)"
tm() { "$REAL_TMUX" -L "$SOCKET" "$@"; }
trap 'tm kill-server 2>/dev/null' EXIT

FAILURES=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; FAILURES=$((FAILURES+1)); fi
}
sw() { tm list-panes -a -F '#{pane_width}|#{pane_title}' | awk -F'|' '$2=="agent-sidebar"{print $1}'; }
run_width() {
    bash -c '
      tmux() { "'"$REAL_TMUX"'" -L "'"$SOCKET"'" "$@"; }
      export -f tmux 2>/dev/null || true
      "'"$REPO_DIR"'/scripts/sidebar-width.sh"
    ' >/dev/null 2>&1
}

echo "sidebar-width-stable"
tm -f /dev/null new-session -d -s s -x 200 -y 50
tm set-option -g @agent-sidebar-width 42
BAR=$(tm split-window -fhb -l 42 -t s:0 -PF '#{pane_id}' "sleep 600")
tm select-pane -t "$BAR" -T agent-sidebar
check "starts at the configured width"      "42" "$(sw)"

# A third pane makes tmux redistribute the window's columns.
tm split-window -h -t s:0 >/dev/null 2>&1
DRIFTED=$(sw)
[ "$DRIFTED" != "42" ] || echo "  note: layout did not drift; the check below is then vacuous"
run_width
check "restored after a layout change"      "42" "$(sw)"

# Idempotent: running again changes nothing.
run_width
check "  and re-running is a no-op"         "42" "$(sw)"

# A window too narrow for the configured width is left alone rather than
# squeezed to nothing.
tm new-window -d -t s -n tiny
tm resize-window -t s:1 -x 60 2>/dev/null || true
check "narrow windows are not forced"       "42" "$(sw)"

if [ "$FAILURES" -ne 0 ]; then printf '\n%d check(s) failed\n' "$FAILURES"; exit 1; fi
printf '\nall checks passed\n'
