#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The Codex hook setup moved out of the README into HOOKS.md, which the README
# links to. Assert against both: the deprecated flag must appear in neither, and
# the current instructions must exist wherever they now live.
README="$REPO_DIR/README.md"
HOOKS_DOC="$REPO_DIR/HOOKS.md"
deprecated_flag="codex""_hooks"

for doc in "$README" "$HOOKS_DOC"; do
    if grep -q "$deprecated_flag" "$doc"; then
        echo "$(basename "$doc") should not document the deprecated Codex hooks feature flag" >&2
        exit 1
    fi
done

grep -q 'hooks = true' "$HOOKS_DOC"
grep -q 'codex --enable hooks' "$HOOKS_DOC"

# ...and the README must still point at it, or the instructions are unreachable.
grep -q 'HOOKS.md' "$README"
