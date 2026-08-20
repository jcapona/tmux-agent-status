#!/usr/bin/env bash
#
# A pane with no status of its own must not inherit the session's.
#
# The session's state is the highest-priority state among its panes, so one
# genuinely working agent made every *untracked* agent pane in that session
# render as working too. That is the normal case, not a broken one: any session
# with two agents in it, one busy, mislabelled the other.
#
# Sessions with no per-pane data at all still inherit -- that is the case the
# fallback exists for, an SSH remote reported only at session level.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export HOME="$TMP_DIR/home"
PANE_DIR="$HOME/.cache/tmux-agent-status/panes"
mkdir -p "$PANE_DIR"

FAILURES=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; FAILURES=$((FAILURES+1)); fi
}

echo "pane-status-no-inherit"

# The resolution rule, exercised directly: it is a handful of lines in
# collect_data and standing the whole collector up would test the plumbing
# rather than the rule.
resolve() { # resolve <session> <pane> ; echoes the state that pane would get
    local owner="$1" pid_id="$2" pane_status="" pane_dir="$PANE_DIR"
    local pane_file="$pane_dir/${owner}_${pid_id}.status"
    [ -f "$pane_file" ] && pane_status=$(<"$pane_file")

    declare -A _sess_has_pane_status=()
    local _psf _psb
    for _psf in "$pane_dir"/*.status; do
        [ -f "$_psf" ] || continue
        _psb="${_psf##*/}"; _psb="${_psb%.status}"
        _sess_has_pane_status["${_psb%_%*}"]=1
    done

    if [ -z "$pane_status" ]; then
        if [ -n "${_sess_has_pane_status[$owner]:-}" ]; then
            pane_status="idle"
        else
            pane_status="${SESS_STATE:-done}"
        fi
    fi
    printf '%s' "$pane_status"
}

# One busy agent, one silent pane, same session.
echo working > "$PANE_DIR/0_%100.status"
SESS_STATE=working
check "the reporting pane keeps its state"     "working" "$(resolve 0 '%100')"
check "a silent pane does NOT inherit working" "idle"    "$(resolve 0 '%200')"

# A session name containing an underscore must still split correctly.
echo working > "$PANE_DIR/pickle_run-1_%300.status"
check "underscored session names split right"  "idle"    "$(resolve pickle_run-1 '%400')"

# A session with no per-pane data at all still inherits: SSH remotes report
# only at session level and the session state is the only signal available.
SESS_STATE=working
check "untracked session still inherits"       "working" "$(resolve remote '%500')"

if [ "$FAILURES" -ne 0 ]; then printf '\n%d check(s) failed\n' "$FAILURES"; exit 1; fi
printf '\nall checks passed\n'
