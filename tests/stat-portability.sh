#!/usr/bin/env bash

# stat -f is the single most portable-looking trap in this codebase. On macOS it
# means "format"; on GNU coreutils it means "filesystem status" -- and crucially
# it prints that block to STDOUT before exiting non-zero. So the tempting idiom
#
#     mtime=$(stat -f %m "$file" || stat -c %Y "$file")
#
# does not save you on Linux: the fallback runs, but the substitution has already
# captured the filesystem block, so you get it concatenated with the real mtime --
# multi-line garbage that blows up the next arithmetic expansion. This shipped twice and only CI on
# ubuntu caught it, because a Mac can never reproduce it.
#
# Every stat -f must therefore sit inside a Darwin branch.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failures=0

check() {
    local label="$1" ok="$2"
    if [ "$ok" -eq 1 ]; then
        echo "  ok    $label"
    else
        echo "  FAIL  $label"
        failures=$((failures + 1))
    fi
}

echo "stat portability"

while IFS= read -r file; do
    while IFS=: read -r lineno _; do
        [ -n "$lineno" ] || continue
        start=$((lineno - 3))
        [ "$start" -lt 1 ] && start=1
        if sed -n "${start},$((lineno - 1))p" "$file" | grep -q 'Darwin'; then
            check "${file#"$REPO_DIR"/}:$lineno is inside a Darwin branch" 1
        else
            check "${file#"$REPO_DIR"/}:$lineno is inside a Darwin branch" 0
        fi
    done < <(grep -n 'stat -f' "$file" | grep -v ':[[:space:]]*#')
done < <(grep -rl 'stat -f' "$REPO_DIR/scripts" 2>/dev/null || true)

# A guard that never runs is not a guard. Make sure we actually inspected the
# known call sites rather than silently matching nothing.
sites=$(grep -rn 'stat -f' "$REPO_DIR/scripts" 2>/dev/null | grep -cv ':[[:space:]]*#' || true)
if [ "${sites:-0}" -ge 1 ]; then
    check "found $sites stat -f call site(s) to check" 1
else
    check "found at least one stat -f call site to check" 0
fi

echo
if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
