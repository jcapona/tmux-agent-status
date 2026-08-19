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
sidebar_win_of() {
    tm list-panes -a -F '#{pane_id} #{window_id}' 2>/dev/null | awk -v p="$1" '$1==p{print $2}'
}
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
run_follow "s1:2"
check "follow off leaves the sidebar alone"   "$START_WIN" "$(sidebar_win)"

# ── on: moves across windows, same pane, same process ──────────────
tm set-option -g @agent-sidebar-follow on
run_follow "s1:2"
check "follow on moves it to the target window" "$(win_of s1:2)" "$(sidebar_win)"
check "  the pane id is unchanged"              "$SIDEBAR_PANE" \
      "$(tm list-panes -a -F '#{pane_id} #{pane_title}' | awk '$2=="agent-sidebar"{print $1}')"
check "  the process was carried, not restarted" "$ORIG_PID" \
      "$(tm display-message -t "$SIDEBAR_PANE" -p '#{pane_pid}')"
check "  still exactly one sidebar"             "1" \
      "$(tm list-panes -a -F '#{pane_title}' | grep -c '^agent-sidebar$')"

# ── same window is not a window switch ─────────────────────────────
BEFORE=$(sidebar_win)
run_follow "s1:2"
check "same-window jump is a no-op"             "$BEFORE" "$(sidebar_win)"

# ── across sessions ────────────────────────────────────────────────
# There is one sidebar in the whole server, so it crosses sessions too.
run_follow "s2:0"
check "follows across sessions"                 "$(win_of s2:0)" "$(sidebar_win_of "$SIDEBAR_PANE")"
check "  process still alive"                   "$ORIG_PID" \
      "$(tm display-message -t "$SIDEBAR_PANE" -p '#{pane_pid}')"
check "  and there is still only one"           "1" \
      "$(tm list-panes -a -F '#{pane_title}' | grep -cx 'agent-sidebar')"

# ── a zoomed destination is unzoomed rather than swallowing the pane ─
tm select-window -t s1:1
tm resize-pane -t s1:1 -Z 2>/dev/null
run_follow "s1:1"
check "zoomed destination still receives it"    "$(win_of s1:1)" "$(sidebar_win)"
check "  and is no longer zoomed"               "0" \
      "$(tm display-message -t s1:1 -p '#{window_zoomed_flag}')"

# ── a destination that already has its own sidebar ─────────────────
# The session-created hook makes one sidebar per session, so arriving at a
# window that already has one is the common case. Joining ours in would stack
# two in the same window, both rendering the same tree.
tm set-option -g @agent-sidebar-follow on
OTHER=$(tm split-window -t s1:2 -PF '#{pane_id}' "sleep 600")
tm select-pane -t "$OTHER" -T "agent-sidebar"
HOME_WIN=$(sidebar_win_of "$SIDEBAR_PANE")
run_follow "s1:2"
check "occupied destination is not doubled up"  "1" \
      "$(tm list-panes -t s1:2 -F '#{pane_title}' | grep -c '^agent-sidebar$')"
check "  and ours stays where it was"           "$HOME_WIN" "$(sidebar_win_of "$SIDEBAR_PANE")"
tm kill-pane -t "$OTHER" 2>/dev/null

# ── a window target that does not exist ────────────────────────────
# tmux resolves a bogus "session:index" to the session's CURRENT window rather
# than failing, so without an explicit check this silently moved the sidebar
# somewhere arbitrary.
HELD=$(sidebar_win_of "$SIDEBAR_PANE")
run_follow "s1:99"
check "nonexistent window target is ignored"    "$HELD" "$(sidebar_win_of "$SIDEBAR_PANE")"

# ── the hook script drives it from tmux's own window changes ───────
# Most window switches are prefix+n / prefix+<digit> / the window list, none of
# which pass through selection_switch_client. Without the hook the sidebar
# stays behind on exactly the switches people make most.
tm set-option -g @agent-sidebar-follow on
TARGET_WIN=$(win_of s1:2)
SIDEBAR_TITLE=agent-sidebar \
PATH="$TMP_DIR/bin:$PATH" bash -c '
  tmux() { "'"$REAL_TMUX"'" -L "'"$SOCKET"'" "$@"; }
  export -f tmux 2>/dev/null || true
  "'"$REPO_DIR"'/scripts/sidebar-follow.sh" "'"$TARGET_WIN"'"
' 2>/dev/null
check "the hook script moves it too"            "$TARGET_WIN" "$(sidebar_win_of "$SIDEBAR_PANE")"

# ── width is stable across repeated moves ──────────────────────────
# Carrying the pane's live width made the sidebar wander: tmux nudges pane
# sizes as layouts change, so each move picked up the drifted value. The
# configured width is re-applied instead, so it lands the same every time.
tm set-option -g @agent-sidebar-follow on
tm set-option -g @agent-sidebar-width 30
run_follow "s1:0"
W1=$(tm display-message -t "$SIDEBAR_PANE" -p '#{pane_width}')
run_follow "s1:1"
W2=$(tm display-message -t "$SIDEBAR_PANE" -p '#{pane_width}')
run_follow "s1:2"
W3=$(tm display-message -t "$SIDEBAR_PANE" -p '#{pane_width}')
check "width is the configured one"             "30" "$W1"
check "  and does not drift over moves"         "30|30" "$W2|$W3"
tm set-option -g @agent-sidebar-width 42

# ── one sidebar, wherever you go ───────────────────────────────────
# The whole point of follow mode: exactly one exists, and it is always in the
# window you just moved to. Never two, never left behind.
tm set-option -g @agent-sidebar-follow on
for w in s1:0 s2:0 s1:2 s1:1 s2:0; do
    run_follow "$w"
    n=$(tm list-panes -a -F '#{pane_title}' | grep -cx 'agent-sidebar')
    [ "$n" = "1" ] || break
done
check "never more than one sidebar exists"      "1" "$n"
check "  and it ends where it was sent"         "$(win_of s2:0)" "$(sidebar_win_of "$SIDEBAR_PANE")"

# ── off again: stops moving ────────────────────────────────────────
tm set-option -g @agent-sidebar-follow off
HELD=$(sidebar_win)
run_follow "s1:2"
check "turning follow off stops the moving"     "$HELD" "$(sidebar_win)"

if [ "$FAILURES" -ne 0 ]; then printf '\n%d check(s) failed\n' "$FAILURES"; exit 1; fi
printf '\nall checks passed\n'
