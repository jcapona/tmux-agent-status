#!/usr/bin/env bash
#
# The sidebar moves its selection with arrow keys as well as j/k.
#
# Arrows arrive in one of two encodings: CSI (ESC [ A) normally, and SS3
# (ESC O A) when the terminal is in application cursor mode. Handling only CSI
# left arrows dead wherever that mode was on while j/k kept working, which reads
# as "the arrow keys do nothing in the sidebar".

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAILURES=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; FAILURES=$((FAILURES+1)); fi
}

echo "sidebar-arrow-keys"

# Both encodings must be accepted for up and for down. Asserted against the
# source rather than a live pane: driving a real terminal into application
# cursor mode from a test is far more fragile than the thing being tested.
up_line=$(grep -n "SELECTED > SESS_START )) && ((SELECTED--))" "$REPO_DIR/scripts/sidebar.sh" | head -1)
dn_line=$(grep -n "SELECTED < SEL_COUNT - 1 )) && ((SELECTED++))" "$REPO_DIR/scripts/sidebar.sh" | head -1)

check "up is bound to CSI (ESC [ A)"   "yes" "$(case "$up_line" in *"'[A'"*) echo yes;; *) echo no;; esac)"
check "up is bound to SS3 (ESC O A)"   "yes" "$(case "$up_line" in *"'OA'"*) echo yes;; *) echo no;; esac)"
check "down is bound to CSI (ESC [ B)" "yes" "$(case "$dn_line" in *"'[B'"*) echo yes;; *) echo no;; esac)"
check "down is bound to SS3 (ESC O B)" "yes" "$(case "$dn_line" in *"'OB'"*) echo yes;; *) echo no;; esac)"

# j/k must keep working; the arrow change must not have replaced them.
check "j still moves down"             "yes" \
      "$(grep -qE '^\s+j\)\s+\(\( SELECTED < SEL_COUNT' "$REPO_DIR/scripts/sidebar.sh" && echo yes || echo no)"
check "k still moves up"               "yes" \
      "$(grep -qE '^\s+k\)\s+\(\( SELECTED > SESS_START' "$REPO_DIR/scripts/sidebar.sh" && echo yes || echo no)"

if [ "$FAILURES" -ne 0 ]; then printf '\n%d check(s) failed\n' "$FAILURES"; exit 1; fi
printf '\nall checks passed\n'
