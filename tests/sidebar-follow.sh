#!/usr/bin/env bash
#
# Follow mode moves the single sidebar pane to whatever window is jumped to,
# instead of spawning one per window or stranding it in one.
#
# The point of moving rather than respawning is that join-pane carries the
# running process with the pane, and the pane id survives -- so the renderer
# never restarts and pane-keyed client tracking stays valid. These checks assert
# exactly that, since a kill-and-recreate implementation would pass a naive
# "is there a sidebar in this window" test while failing the whole design.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCKET="followtest$$"
TMP_DIR="$(mktemp -d)"
REAL_TMUX="$(command -v tmux)"
tm() { "$REAL_TMUX" -L "$SOCKET" "$@"; }
cleanup() { tm kill-server 2>/dev/null; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

FAILURES=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; FAILURES=$((FAILURES+1)); fi
}

echo "sidebar-follow"

tm -f /dev/null new-session -d -s s1 -x 200 -y 50
tm new-window -d -t s1 -n w2
tm new-window -d -t s1 -n w3
tm new-session -d -s s2 -x 200 -y 50

# A stand-in for the renderer: a long-lived process tagged like a real sidebar,
# so "did the process survive the move" is observable.
SIDEBAR_PANE=$(tm split-window -t s1:1 -PF '#{pane_id}' "sleep 600")
tm select-pane -t "$SIDEBAR_PANE" -T "agent-sidebar"
ORIG_PID=$(tm display-message -t "$SIDEBAR_PANE" -p '#{pane_pid}')

win_of() { tm display-message -t "$1" -p '#{window_id}' 2>/dev/null; }
sidebar_win() {
    tm list-panes -a -F '#{pane_id} #{window_id} #{pane_title}' 2>/dev/null \
      | awk '$3=="agent-sidebar"{print $2}'
}

# shellcheck source=/dev/null
export SIDEBAR_TITLE="agent-sidebar"
run_follow() {
    PATH="$TMP_DIR/bin:$PATH" \
    bash -c '
      tmux() { "'"$REAL_TMUX"'" -L "'"$SOCKET"'" "$@"; }
      export -f tmux 2>/dev/null || true
      SIDEBAR_TITLE=agent-sidebar
      source "'"$REPO_DIR"'/scripts/lib/selection-targets.sh"
      sidebar_follow_to_window "'"$1"'"
    '
}

# ── off by default: nothing moves ──────────────────────────────────
START_WIN=$(sidebar_win)
run_follow "s1:3"
check "follow off leaves the sidebar alone"   "$START_WIN" "$(sidebar_win)"

# ── on: moves across windows, same pane, same process ──────────────
tm set-option -g @agent-sidebar-follow on
run_follow "s1:3"
check "follow on moves it to the target window" "$(win_of s1:3)" "$(sidebar_win)"
check "  the pane id is unchanged"              "$SIDEBAR_PANE" \
      "$(tm list-panes -a -F '#{pane_id} #{pane_title}' | awk '$2=="agent-sidebar"{print $1}')"
check "  the process was carried, not restarted" "$ORIG_PID" \
      "$(tm display-message -t "$SIDEBAR_PANE" -p '#{pane_pid}')"
check "  still exactly one sidebar"             "1" \
      "$(tm list-panes -a -F '#{pane_title}' | grep -c '^agent-sidebar$')"

# ── same window is not a window switch ─────────────────────────────
BEFORE=$(sidebar_win)
run_follow "s1:3"
check "same-window jump is a no-op"             "$BEFORE" "$(sidebar_win)"

# ── across sessions ────────────────────────────────────────────────
run_follow "s2:1"
check "follows across sessions too"             "$(win_of s2:1)" "$(sidebar_win)"
check "  process still alive after 2 moves"     "$ORIG_PID" \
      "$(tm display-message -t "$SIDEBAR_PANE" -p '#{pane_pid}')"

# ── a zoomed destination is unzoomed rather than swallowing the pane ─
tm select-window -t s1:2
tm resize-pane -t s1:2 -Z 2>/dev/null
run_follow "s1:2"
check "zoomed destination still receives it"    "$(win_of s1:2)" "$(sidebar_win)"
check "  and is no longer zoomed"               "0" \
      "$(tm display-message -t s1:2 -p '#{window_zoomed_flag}')"

# ── off again: stops moving ────────────────────────────────────────
tm set-option -g @agent-sidebar-follow off
HELD=$(sidebar_win)
run_follow "s1:3"
check "turning follow off stops the moving"     "$HELD" "$(sidebar_win)"

if [ "$FAILURES" -ne 0 ]; then printf '\n%d check(s) failed\n' "$FAILURES"; exit 1; fi
printf '\nall checks passed\n'
