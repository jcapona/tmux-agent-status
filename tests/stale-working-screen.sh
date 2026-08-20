#!/usr/bin/env bash
#
# A "working" status is disbelieved when the pane's own screen stops changing.
#
# State is pushed by hooks and nothing expires it, so a Stop that never fires
# leaves "working" set forever -- observed at 908 minutes with the agent process
# alive and idle, which is why process liveness does not catch this.
#
# #{window_activity} was tried first and is too coarse: window-level, so a shell
# in the same window -- or follow mode joining the sidebar in or out of it --
# resets the clock. Measured directly: a pane 903 minutes stale sat in a window
# reporting output 1 minute ago. The pane's own visible text is the per-pane
# equivalent, and an agent that is working repaints.
#
# The rule resolves to "idle", never "done": the honest claim is "no longer
# believable", not "finished".

set -uo pipefail

FAILURES=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; FAILURES=$((FAILURES+1)); fi
}

echo "stale-working-screen"

# The rule itself. Standing up the whole collector would exercise the tmux
# plumbing rather than the decision, and the decision is what can be wrong.
resolve() { # resolve <status> <secs-since-screen-changed> <threshold-secs>
    local pane_status="$1" age="$2" STALE_WORKING_SECS="$3"
    local now=1000000 _last=$(( 1000000 - age ))
    if [ "$pane_status" = "working" ] && (( STALE_WORKING_SECS > 0 )); then
        if [ -n "$_last" ] && (( _last > 0 )) && (( now - _last > STALE_WORKING_SECS )); then
            pane_status="idle"
        fi
    fi
    printf '%s' "$pane_status"
}

T=1200   # 20 minutes

check "a changing screen keeps working"          "working" "$(resolve working 10 $T)"
check "just under the threshold holds"      "working" "$(resolve working 1199 $T)"
check "past the threshold is disbelieved"   "idle"    "$(resolve working 1201 $T)"
check "the 15-hour case is caught"       "idle"    "$(resolve working 9480 $T)"

# It must never invent completion, and never touch other states.
check "stale working becomes idle, not done" "idle"   "$(resolve working 99999 $T)"
check "done is left alone"                   "done"   "$(resolve done 99999 $T)"

# 0 disables the check entirely, restoring pure hook-driven state.
check "0 disables the rule"                  "working" "$(resolve working 99999 0)"

# A window with no activity timestamp at all must not be treated as stale.
resolve_noact() {
    local pane_status="working" STALE_WORKING_SECS=1200 now=1000000 _last=""
    if [ "$pane_status" = "working" ] && (( STALE_WORKING_SECS > 0 )); then
        if [ -n "$_last" ] && (( _last > 0 )) && (( now - _last > STALE_WORKING_SECS )); then
            pane_status="idle"
        fi
    fi
    printf '%s' "$pane_status"
}
check "an unseen pane is not stale"     "working" "$(resolve_noact)"

if [ "$FAILURES" -ne 0 ]; then printf '\n%d check(s) failed\n' "$FAILURES"; exit 1; fi
printf '\nall checks passed\n'
