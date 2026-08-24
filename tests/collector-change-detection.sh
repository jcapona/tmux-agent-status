#!/usr/bin/env bash
#
# The collector used to force a full rebuild every ten calls because its mtime
# check only watches our own files. That sweep cost ~290ms on a busy server and
# was the single most expensive thing it did.
#
# Most tmux-side changes already arrive as hooks that touch REFRESH_FILE. What
# has no hook is a window rename, so that is what the shape fingerprint has to
# catch -- cheaply, and without a sweep.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export HOME="$TMP_DIR/home"
PANE_DIR="$HOME/.cache/tmux-agent-status/panes"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$PANE_DIR" "$FAKE_BIN"

FAILURES=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; FAILURES=$((FAILURES+1)); fi
}

# Fake tmux whose window name we can change between collections, standing in
# for a rename that fires no hook.
NAME_FILE="$TMP_DIR/wname"; printf 'alpha\n' > "$NAME_FILE"
cat > "$FAKE_BIN/tmux" <<TMUXEOF
#!/usr/bin/env bash
set -uo pipefail
case "\${1:-}" in
    list-sessions) printf 'repo\n' ;;
    list-panes)
        if [ "\${2:-}" = "-a" ]; then
            printf 'repo\t%%1\t/tmp/repo\t101\t0\t%s\t1\t0\n' "\$(cat "$NAME_FILE")"
        fi
        ;;
    show-option) : ;;
    *) : ;;
esac
exit 0
TMUXEOF
chmod +x "$FAKE_BIN/tmux"
printf 'working\n' > "$PANE_DIR/repo_%1.status"
printf 'claude\n'  > "$PANE_DIR/repo_%1.agent"

BASH_BIN="$(command -v bash)"
for _c in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$_c" ] && BASH_BIN="$_c" && break
done

echo "collector-change-detection"

result=$(PATH="$FAKE_BIN:$PATH" "$BASH_BIN" -c '
    source "'"$REPO_DIR"'/scripts/lib/session-status.sh"
    source "'"$REPO_DIR"'/scripts/lib/collect.sh"
    source "'"$REPO_DIR"'/scripts/lib/status-summary.sh"
    source "'"$REPO_DIR"'/scripts/lib/sidebar-clients.sh"
    declare -A KNOWN_AGENTS=() LIVE_PANES=() PID_PPID=() PANE_COUNTS=()
    declare -A _SCREEN_HASH=() _SCREEN_TS=(); _SCREEN_LAST_SAMPLE=0
    ENTRIES=(); SEL_NAMES=(); SEL_TYPES=(); SESS_START=0
    _COLLECT_TICK=0; _LAST_STATUS_MTIME=""; _LAST_SHAPE=""; _COLLECT_CHANGED=0
    SUMMARY_WORKING=0; SUMMARY_DONE=0; SUMMARY_TOTAL=0; SUMMARY_HAS_WORKING=0

    collect_data >/dev/null 2>&1;            first=$_COLLECT_CHANGED
    collect_data >/dev/null 2>&1;            second=$_COLLECT_CHANGED
    printf "beta\n" > "'"$NAME_FILE"'"
    collect_data >/dev/null 2>&1;            renamed=$_COLLECT_CHANGED
    collect_data >/dev/null 2>&1;            after=$_COLLECT_CHANGED
    printf "%s %s %s %s\n" "$first" "$second" "$renamed" "$after"
' 2>/dev/null)

read -r first second renamed after <<< "$result"
check "first collection builds"                     "1" "${first:-}"
check "an unchanged tick short-circuits"            "0" "${second:-}"
check "a window rename is noticed with no hook"     "1" "${renamed:-}"
check "and settles again afterwards"                "0" "${after:-}"

# The sweep must not come back at ten: that is what made it expensive.
if grep -qE '_COLLECT_TICK >= 10\b' "$REPO_DIR/scripts/lib/collect.sh"; then
    check "no 10-tick forced sweep" "absent" "present"
else
    check "no 10-tick forced sweep" "absent" "absent"
fi

# The idle backoff must never let the cache age past what the switcher will
# accept. cached_pane_status treats anything older than SIDEBAR_CACHE_MAX_AGE
# as unusable and re-derives from raw files, which is the sidebar/switcher
# disagreement the shared-state work removed. Raising the idle interval past
# that ceiling would reintroduce it silently.
idle=$(grep -oE 'IDLE_COLLECT_SECS=[0-9]+' "$REPO_DIR/scripts/sidebar-collector.sh" | head -1 | cut -d= -f2)
maxage=$(grep -oE 'SIDEBAR_CACHE_MAX_AGE=[0-9]+' "$REPO_DIR/scripts/lib/session-status.sh" | head -1 | cut -d= -f2)
if [ -n "$idle" ] && [ -n "$maxage" ] && [ "$idle" -lt "$maxage" ]; then
    check "idle interval stays inside the switcher's freshness window" "yes" "yes"
else
    check "idle interval stays inside the switcher's freshness window" "yes" "no ($idle vs $maxage)"
fi

echo
if [ "$FAILURES" -ne 0 ]; then echo "$FAILURES check(s) failed"; exit 1; fi
echo "all checks passed"
