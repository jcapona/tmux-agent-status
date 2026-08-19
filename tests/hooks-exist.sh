#!/usr/bin/env bash
#
# Every hook the entrypoint registers must be a hook tmux actually has.
#
# tmux silently accepts unknown hook names: `set-hook -g window-layout-changed
# ...` exits 0, prints nothing, and never shows up in `show-hooks -g`. A typo or
# an invented name therefore looks registered forever and never fires. That is
# not hypothetical -- the collector was hooked to window-layout-changed, which
# does not exist, so it was never told a window's layout had changed.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCKET="hookcheck$$"
REAL_TMUX="$(command -v tmux)"
trap '"$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null' EXIT

echo "hooks-exist"

"$REAL_TMUX" -L "$SOCKET" -f /dev/null new-session -d 2>/dev/null

# The set of hook names this tmux supports.
"$REAL_TMUX" -L "$SOCKET" show-hooks -g 2>/dev/null \
    | sed 's/\[.*//; s/ .*//' | sort -u > "/tmp/.hooks-known.$$"

# The hook names the entrypoint registers.
grep -oE '^add_hook_once [a-z-]+' "$REPO_DIR/tmux-agent-status.tmux" \
    | awk '{print $2}' | sort -u > "/tmp/.hooks-used.$$"

FAILURES=0
while read -r h; do
    [ -n "$h" ] || continue
    if grep -qx "$h" "/tmp/.hooks-known.$$"; then
        printf '  ok    %s\n' "$h"
    else
        printf '  FAIL  %s  <- tmux has no such hook; it will never fire\n' "$h"
        FAILURES=$((FAILURES + 1))
    fi
done < "/tmp/.hooks-used.$$"

used=$(wc -l < "/tmp/.hooks-used.$$" | tr -d ' ')
rm -f "/tmp/.hooks-known.$$" "/tmp/.hooks-used.$$"

if [ "$used" -eq 0 ]; then
    echo "  FAIL  found no add_hook_once calls to check — has the entrypoint changed shape?"
    exit 1
fi

if [ "$FAILURES" -ne 0 ]; then printf '\n%d hook(s) do not exist\n' "$FAILURES"; exit 1; fi
printf '\nall %s hooks exist\n' "$used"
