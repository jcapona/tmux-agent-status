#!/usr/bin/env bash
#
# The INBOX section is opt-in via @agent-sidebar-inbox, default off.
#
# prefix+N walks the same rows the section is built from, so gating collection
# would have silently turned "jump to the next done item" into a permanent
# "No inbox items". next-done-project.sh sets INBOX_FORCE to keep its rows
# regardless of the option; this test pins that down so the two cannot drift.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="$TMP_DIR/home"
STATUS_DIR="$HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN" "$PANE_DIR"

FAILURES=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; FAILURES=$((FAILURES+1)); fi
}

# A fake tmux whose @agent-sidebar-inbox answer we can vary per run.
make_tmux() { # <inbox-option-value>
    cat > "$FAKE_BIN/tmux" <<TMUXEOF
#!/usr/bin/env bash
set -uo pipefail
case "\${1:-}" in
    show-option)
        case "\${3:-}" in
            @agent-sidebar-inbox) printf '%s\n' "$1" ;;
            *) : ;;
        esac
        exit 0 ;;
    list-sessions) printf 'repo\n'; exit 0 ;;
    list-panes)
        if [ "\${2:-}" = "-a" ]; then
            printf 'repo\t%%1\t/home/test/repo\t101\t0\tmain\t1\t0\n'
        fi
        exit 0 ;;
    display-message) exit 0 ;;
    *) exit 0 ;;
esac
TMUXEOF
    chmod +x "$FAKE_BIN/tmux"
}

printf 'done\n'   > "$PANE_DIR/repo_%1.status"
printf 'claude\n' > "$PANE_DIR/repo_%1.agent"

echo "sidebar-inbox-option"

BASH_BIN="$(command -v bash)"
for _c in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$_c" ] && BASH_BIN="$_c" && break
done

collect_with() { # <option-value> [force]
    make_tmux "$1"
    PATH="$FAKE_BIN:$PATH" INBOX_FORCE="${2:-0}" "$BASH_BIN" -c '
        # Same load order as sidebar-collector.sh: session-status.sh defines
        # STATUS_DIR, which collect.sh expects from its caller.
        source "'"$REPO_DIR"'/scripts/lib/session-status.sh"
        source "'"$REPO_DIR"'/scripts/lib/collect.sh"
        source "'"$REPO_DIR"'/scripts/lib/status-summary.sh"
        source "'"$REPO_DIR"'/scripts/lib/sidebar-clients.sh"
        declare -A KNOWN_AGENTS=() LIVE_PANES=() PID_PPID=() PANE_COUNTS=()
        declare -A _SCREEN_HASH=() _SCREEN_TS=(); _SCREEN_LAST_SAMPLE=0
        ENTRIES=(); SEL_NAMES=(); SEL_TYPES=(); SESS_START=0
        _COLLECT_TICK=0; _LAST_STATUS_MTIME=""; _COLLECT_CHANGED=0
        SUMMARY_WORKING=0; SUMMARY_DONE=0; SUMMARY_TOTAL=0; SUMMARY_HAS_WORKING=0
        collect_data >/dev/null 2>&1
        printf "%s\n" "${ENTRIES[@]}"
    ' 2>/dev/null | grep -c '^G|INBOX' | tr -d ' '
}

check "off by default"                 "0" "$(collect_with '')"
check "stays off when explicitly off"  "0" "$(collect_with 'off')"
check "on when enabled"                "1" "$(collect_with 'on')"
check "on for 1/true/yes"              "1" "$(collect_with 'true')"
check "prefix+N still gets its rows"   "1" "$(collect_with '' 1)"

# The jump must actually set the override, not merely tolerate it.
if grep -q 'INBOX_FORCE=1' "$REPO_DIR/scripts/next-done-project.sh"; then
    check "next-done-project.sh sets the override" "yes" "yes"
else
    check "next-done-project.sh sets the override" "yes" "no"
fi

echo
if [ "$FAILURES" -ne 0 ]; then echo "$FAILURES check(s) failed"; exit 1; fi
echo "all checks passed"
