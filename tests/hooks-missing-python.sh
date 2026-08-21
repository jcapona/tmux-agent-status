#!/usr/bin/env bash
#
# hooks.sh edits JSON config and refuses to run without python3. That refusal
# used to be worse than useless: the message interpolated $SETTINGS, a variable
# that is defined nowhere in the script, so under `set -u` the error path itself
# died with "SETTINGS: unbound variable" instead of telling you to install
# python3. Only a machine without python3 could see it, so it shipped.
#
# Assert on the message, not just the exit status -- a non-zero exit was never
# the broken part.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="$TMP_DIR/home"
mkdir -p "$HOME"

FAILURES=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; FAILURES=$((FAILURES+1)); fi
}

echo "hooks-missing-python"

# A PATH with a shell but deliberately no python3.
STUB="$TMP_DIR/bin"
mkdir -p "$STUB"
for c in bash sh grep sed cat mkdir rm cp mv chmod dirname basename command tmux; do
    src="$(command -v "$c" 2>/dev/null)" && ln -sf "$src" "$STUB/$c" 2>/dev/null
done

out=$(PATH="$STUB" CLAUDE_SETTINGS="$TMP_DIR/settings.json" \
      bash "$REPO_DIR/scripts/hooks.sh" install claude 2>&1)
rc=$?

check "refuses to run without python3" "1" "$rc"

case "$out" in
    *"unbound variable"*)
        check "reports the real problem, not an unbound variable" "clean message" "unbound variable: $out" ;;
    *"python3 is required"*)
        check "reports the real problem, not an unbound variable" "clean message" "clean message" ;;
    *)
        check "reports the real problem, not an unbound variable" "clean message" "unexpected: $out" ;;
esac

echo
if [ "$FAILURES" -ne 0 ]; then echo "$FAILURES check(s) failed"; exit 1; fi
echo "all checks passed"
