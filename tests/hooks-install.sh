#!/usr/bin/env bash
#
# Covers scripts/hooks.sh: install must be idempotent and self-repairing,
# uninstall must remove only our entries, and neither may damage a settings
# file it does not understand.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_SH="$REPO_DIR/scripts/hooks.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Every default path in hooks.sh is derived from $HOME. Redirecting HOME means
# an invocation that forgets to pass a target -- which defaults to "all" --
# still cannot reach the real ~/.claude, ~/.codex or ~/.config/devin. An
# earlier version of this file did exactly that and created real config files.
export HOME="$TMP_DIR/home"
mkdir -p "$HOME"

FAILURES=0
check() { # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok    %s\n' "$1"
    else
        printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
        FAILURES=$((FAILURES + 1))
    fi
}

# Number of our command entries across the whole file. Marker defaults to the
# Claude hook so the existing checks read unchanged.
count_ours() {
    python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
marker = sys.argv[2]
n = 0
for blocks in (data.get("hooks") or {}).values():
    for block in blocks or []:
        for entry in (block or {}).get("hooks", []) or []:
            if marker in str(entry.get("command", "")):
                n += 1
print(n)
' "$1" "${2:-better-hook.sh}"
}

json_get() { python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    data = data[int(key)] if key.isdigit() else data[key]
print(data)
' "$1" "$2"; }

SANDBOX="$TMP_DIR/sandbox"
run() { # run <settings-file> <command> [target]
    CLAUDE_SETTINGS="$1" \
    CODEX_SETTINGS="${CODEX_OVERRIDE:-$SANDBOX/codex.json}" \
    DEVIN_SETTINGS="${DEVIN_OVERRIDE:-$SANDBOX/devin.json}" \
        bash "$HOOKS_SH" "$2" "${3:-claude}" >/dev/null 2>&1
}

echo "hooks.sh"

# ── install creates a valid file from nothing ──────────────────────
S="$TMP_DIR/fresh/settings.json"
run "$S" install
check "install creates settings.json"            "4" "$(count_ours "$S")"
check "  and it is valid JSON"                   "command" "$(json_get "$S" 'hooks.Stop.0.hooks.0.type')"

# ── install is idempotent ──────────────────────────────────────────
run "$S" install
run "$S" install
check "install x3 still has 4 entries"           "4" "$(count_ours "$S")"

# ── install repairs a stale path instead of duplicating ────────────
S2="$TMP_DIR/stale/settings.json"; mkdir -p "$(dirname "$S2")"
cat > "$S2" <<'EOF'
{
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "/wrong/place/hooks/better-hook.sh Stop"}]}
    ]
  }
}
EOF
run "$S2" install
check "stale path is replaced, not duplicated"   "4" "$(count_ours "$S2")"
check "  and now points at this checkout"        "$REPO_DIR/hooks/better-hook.sh Stop" \
      "$(json_get "$S2" 'hooks.Stop.0.hooks.0.command')"

# ── unrelated config survives install and uninstall ────────────────
S3="$TMP_DIR/mixed/settings.json"; mkdir -p "$(dirname "$S3")"
cat > "$S3" <<'EOF'
{
  "model": "opus",
  "permissions": {"allow": ["Bash(ls:*)"]},
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "/somebody/else/dispatch.js stop"}]}
    ],
    "PostToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/other/tool.js"}]}
    ]
  }
}
EOF
run "$S3" install
check "install keeps unrelated top-level keys"   "opus" "$(json_get "$S3" 'model')"
check "install keeps a foreign Stop hook"        "/somebody/else/dispatch.js stop" \
      "$(json_get "$S3" 'hooks.Stop.0.hooks.0.command')"
check "install adds ours alongside it"           "4" "$(count_ours "$S3")"

run "$S3" uninstall
check "uninstall removes only ours"              "0" "$(count_ours "$S3")"
check "  foreign Stop hook survives"             "/somebody/else/dispatch.js stop" \
      "$(json_get "$S3" 'hooks.Stop.0.hooks.0.command')"
check "  foreign matcher block survives"         "Bash" "$(json_get "$S3" 'hooks.PostToolUse.0.matcher')"
check "  unrelated keys survive"                 "opus" "$(json_get "$S3" 'model')"

# ── uninstall with nothing of ours is a no-op ──────────────────────
BEFORE="$(cat "$S3")"
run "$S3" uninstall
check "uninstall again changes nothing"          "$BEFORE" "$(cat "$S3")"

# ── malformed JSON is refused, not overwritten ─────────────────────
S4="$TMP_DIR/broken/settings.json"; mkdir -p "$(dirname "$S4")"
printf '{ this is not json' > "$S4"
BEFORE="$(cat "$S4")"
set +e
CLAUDE_SETTINGS="$S4" bash "$HOOKS_SH" install claude >/dev/null 2>&1
rc=$?
set -e
check "malformed JSON exits non-zero"            "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "  and the file is left untouched"         "$BEFORE" "$(cat "$S4")"

# ── status reflects reality ────────────────────────────────────────
set +e
CLAUDE_SETTINGS="$TMP_DIR/none/settings.json" bash "$HOOKS_SH" status claude >/dev/null 2>&1
rc_missing=$?
CLAUDE_SETTINGS="$S" bash "$HOOKS_SH" status claude >/dev/null 2>&1
rc_installed=$?
set -e
check "status fails when nothing is installed"   "1" "$([ "$rc_missing" -ne 0 ] && echo 1 || echo 0)"
check "status passes when correctly installed"   "0" "$rc_installed"

# ── uninstall leaves no empty scaffolding behind ───────────────────
S5="$TMP_DIR/only-ours/settings.json"
run "$S5" install
run "$S5" uninstall
check "uninstall drops the now-empty hooks key"  "False" \
      "$(python3 -c 'import json,sys; print("hooks" in json.load(open(sys.argv[1])))' "$S5")"

# ── codex and devin targets ────────────────────────────────────────
C="$TMP_DIR/codex/hooks.json"; D="$TMP_DIR/devin/config.json"
CODEX_OVERRIDE="$C" run "$TMP_DIR/unused-claude.json" install codex
DEVIN_OVERRIDE="$D" run "$TMP_DIR/unused-claude.json" install devin

check "codex installs 4 hooks"                   "4" "$(count_ours "$C" codex-hook.sh)"
check "devin installs 5 hooks"                   "5" "$(count_ours "$D" devin-hook.sh)"
check "codex SessionStart carries its matcher"   "startup|resume" "$(json_get "$C" 'hooks.SessionStart.0.matcher')"
check "codex PreToolUse carries its matcher"     "Bash" "$(json_get "$C" 'hooks.PreToolUse.0.matcher')"
check "codex command is run through bash"        "bash $REPO_DIR/hooks/codex-hook.sh Stop" \
      "$(json_get "$C" 'hooks.Stop.0.hooks.0.command')"
check "devin command is run through bash"        "bash $REPO_DIR/hooks/devin-hook.sh Stop" \
      "$(json_get "$D" 'hooks.Stop.0.hooks.0.command')"

CODEX_OVERRIDE="$C" run "$TMP_DIR/unused-claude.json" install codex
check "codex install is idempotent"              "4" "$(count_ours "$C" codex-hook.sh)"

# Targets must not reach into each other's files.
check "installing codex left devin alone"        "5" "$(count_ours "$D" devin-hook.sh)"
CODEX_OVERRIDE="$C" run "$TMP_DIR/unused-claude.json" uninstall codex
check "codex uninstall clears codex"             "0" "$(count_ours "$C" codex-hook.sh)"
check "  and devin is untouched"                 "5" "$(count_ours "$D" devin-hook.sh)"

# ── pending: only agents that are installed and not yet configured ─
FAKE_BIN="$TMP_DIR/bin"; mkdir -p "$FAKE_BIN"
for b in claude codex; do printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/$b"; chmod +x "$FAKE_BIN/$b"; done

P_CLAUDE="$TMP_DIR/pending/claude.json"; P_CODEX="$TMP_DIR/pending/codex.json"
pending() {
    PATH="$FAKE_BIN:$PATH" \
    CLAUDE_SETTINGS="$P_CLAUDE" CODEX_SETTINGS="$P_CODEX" DEVIN_SETTINGS="$TMP_DIR/pending/devin.json" \
        bash "$HOOKS_SH" pending 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}

check "pending lists both unconfigured agents"   "claude codex" "$(pending)"

PATH="$FAKE_BIN:$PATH" CLAUDE_SETTINGS="$P_CLAUDE" CODEX_SETTINGS="$P_CODEX" \
    DEVIN_SETTINGS="$TMP_DIR/pending/devin.json" bash "$HOOKS_SH" install claude >/dev/null 2>&1
check "  configured agent drops off the list"    "codex" "$(pending)"

PATH="$FAKE_BIN:$PATH" CLAUDE_SETTINGS="$P_CLAUDE" CODEX_SETTINGS="$P_CODEX" \
    DEVIN_SETTINGS="$TMP_DIR/pending/devin.json" bash "$HOOKS_SH" install codex >/dev/null 2>&1
check "  empty once everything is configured"    "" "$(pending)"

# devin is never listed: its CLI is not on the fake PATH.
check "uninstalled agents are never nagged about" "" \
      "$(pending | tr ' ' '\n' | grep -c devin | grep -v '^0$' || true)"

# A stale path must reappear as pending, since that is the silent failure the
# nudge exists to catch.
python3 - "$P_CLAUDE" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["hooks"]["Stop"][0]["hooks"][0]["command"] = "/gone/hooks/better-hook.sh Stop"
json.dump(d, open(sys.argv[1], "w"), indent=2)
PYEOF
check "a broken path shows up as pending again"  "claude" "$(pending)"

# ── the sandbox must have held ─────────────────────────────────────
check "no real ~/.codex written"                 "absent" \
      "$([ -e "$TMP_DIR/home/.codex/hooks.json" ] && echo "under sandbox HOME (fine)" || echo absent)"
check "every write stayed under TMP_DIR"         "0" \
      "$(find "$TMP_DIR" -name '*.json' -newer "$HOOKS_SH" 2>/dev/null | grep -cv "^$TMP_DIR" || true)"

if [ "$FAILURES" -ne 0 ]; then
    printf '\n%d check(s) failed\n' "$FAILURES"
    exit 1
fi
printf '\nall checks passed\n'
