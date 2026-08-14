#!/usr/bin/env bash
#
# Install, remove and check this plugin's agent hooks (Claude, Codex, Devin).
#
#   hooks.sh install   [claude|codex|devin|all]   add or repair the hooks
#   hooks.sh uninstall [claude|codex|devin|all]   remove only this plugin's hooks
#   hooks.sh status    [claude|codex|devin|all]   report what is configured
#   hooks.sh pending                                 list agents needing install
#
# The target defaults to "all". Agents whose hook script is missing are skipped.
#
# Hand-editing settings.json is the usual way to set these up, and it fails
# quietly: a wrong path means the hook never runs, the agent keeps working, and
# its state simply never reaches the plugin. That reads as broken tracking
# rather than a typo, so this script owns the edit instead.
#
# CLAUDE_SETTINGS / CODEX_SETTINGS / DEVIN_SETTINGS override the file each
# target edits (used by the tests).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Paths are resolved at run time from this script's own location, so what gets
# written is correct whichever way the plugin was installed -- tpm's default
# directory, a custom TMUX_PLUGIN_MANAGER_PATH, or a manual clone anywhere.

# Per-agent configuration. Each target names the file it edits, the hook script
# it installs, the events it registers, and whether that agent expects the
# command to be run through bash. Events may carry a matcher as "Event=matcher".
#
# Entries are identified by the hook script's filename rather than by an exact
# path, so a plugin that has been moved -- or was configured with a wrong path
# by hand -- is still recognised as ours, and install repairs it instead of
# adding a duplicate.
target_settings() {
    case "$1" in
        claude) printf '%s' "${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}" ;;
        codex)  printf '%s' "${CODEX_SETTINGS:-$HOME/.codex/hooks.json}" ;;
        devin)  printf '%s' "${DEVIN_SETTINGS:-$HOME/.config/devin/config.json}" ;;
    esac
}

target_hook() {
    case "$1" in
        claude) printf '%s' "$PLUGIN_DIR/hooks/better-hook.sh" ;;
        codex)  printf '%s' "$PLUGIN_DIR/hooks/codex-hook.sh" ;;
        devin)  printf '%s' "$PLUGIN_DIR/hooks/devin-hook.sh" ;;
    esac
}

target_events() {
    case "$1" in
        claude) printf '%s' "UserPromptSubmit PreToolUse Stop Notification" ;;
        codex)  printf '%s' "SessionStart=startup|resume UserPromptSubmit PreToolUse=Bash Stop" ;;
        devin)  printf '%s' "SessionStart UserPromptSubmit PreToolUse PostToolUse Stop" ;;
    esac
}

# Codex and Devin document the command as "bash <script> <Event>"; Claude does
# not. Kept per target so what is written matches each agent's own docs.
target_prefix() {
    case "$1" in
        claude) printf '%s' "" ;;
        *)      printf '%s' "bash " ;;
    esac
}

# The CLI each target belongs to. Used to decide whether an agent is worth
# mentioning at all: a machine without codex installed should never be told its
# codex hooks are missing.
target_binary() {
    case "$1" in
        claude) printf '%s' "claude" ;;
        codex)  printf '%s' "codex" ;;
        devin)  printf '%s' "devin" ;;
    esac
}

TARGETS="claude codex devin"

usage() {
    sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_python() {
    command -v python3 >/dev/null 2>&1 ||
        die "python3 is required to edit $SETTINGS safely (JSON is not something to patch with sed)"
}

# All JSON work happens here. The file is parsed before anything is written, so
# a malformed settings.json is reported instead of being overwritten, and the
# new content is written to a temporary file and renamed, so an interrupted run
# cannot leave a half-written settings.json behind.
run_python() {
    local mode="$1" target="$2"
    python3 - "$mode" "$(target_settings "$target")" "$(target_hook "$target")" \
        "$(basename "$(target_hook "$target")")" "$(target_prefix "$target")" \
        $(target_events "$target") <<'PY'
import json, os, shutil, sys, time

mode, settings_path, hook_script, marker, prefix, *event_specs = sys.argv[1:]

# "Event" or "Event=matcher"
events = []
for spec in event_specs:
    name, _, matcher = spec.partition("=")
    events.append((name, matcher))
event_names = [name for name, _ in events]

def load(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return {}, False
    with open(path) as fh:
        try:
            data = json.load(fh)
        except json.JSONDecodeError as exc:
            sys.exit(f"error: {path} is not valid JSON ({exc}); refusing to touch it")
    if not isinstance(data, dict):
        sys.exit(f"error: {path} does not contain a JSON object; refusing to touch it")
    return data, True

def is_ours(entry):
    return isinstance(entry, dict) and marker in str(entry.get("command", ""))

def strip_ours(hooks):
    """Drop our command entries, then any block or event left empty by that.

    Only entries matching the marker are removed. Blocks that also hold other
    people's hooks keep them, and unrelated events are untouched.
    """
    removed = 0
    for event in list(hooks):
        blocks = hooks.get(event)
        if not isinstance(blocks, list):
            continue
        kept_blocks = []
        for block in blocks:
            if not isinstance(block, dict) or not isinstance(block.get("hooks"), list):
                kept_blocks.append(block)
                continue
            kept = [h for h in block["hooks"] if not is_ours(h)]
            removed += len(block["hooks"]) - len(kept)
            if kept:
                block["hooks"] = kept
                kept_blocks.append(block)
            elif len(block) > 1:
                # Block carried other keys (e.g. a matcher) and nothing else of
                # ours; drop it only because it is now empty of hooks.
                continue
        if kept_blocks:
            hooks[event] = kept_blocks
        else:
            del hooks[event]
    return removed

def write(path, data):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)

data, existed = load(settings_path)
hooks = data.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}

if mode == "status":
    found = []
    for event in event_names:
        for block in hooks.get(event, []) or []:
            if not isinstance(block, dict):
                continue
            for entry in block.get("hooks", []) or []:
                if is_ours(entry):
                    found.append((event, str(entry.get("command", ""))))
    print(f"settings: {settings_path}{'' if existed else ' (does not exist)'}")
    print(f"expected: {hook_script}")
    if not found:
        print("hooks:    none installed")
        sys.exit(1)
    ok = True
    for event in event_names:
        matches = [cmd for ev, cmd in found if ev == event]
        if not matches:
            print(f"  {event:<18} MISSING")
            ok = False
            continue
        for cmd in matches:
            # Commands are run through a shell, so they legitimately contain
            # $HOME / ${HOME} / ~ -- expand the same way before testing the
            # path, or a perfectly good hook is reported as broken.
            parts = cmd.split()
            script = parts[1] if parts and parts[0] == "bash" and len(parts) > 1 else parts[0]
            path = os.path.expanduser(os.path.expandvars(script))
            if len(matches) > 1:
                print(f"  {event:<18} DUPLICATE  {cmd}")
                ok = False
            elif not os.path.exists(path):
                print(f"  {event:<18} BROKEN     {cmd}  <- path does not exist")
                ok = False
            elif not os.access(path, os.X_OK):
                print(f"  {event:<18} NOT EXEC   {cmd}")
                ok = False
            elif os.path.realpath(path) != os.path.realpath(hook_script):
                print(f"  {event:<18} STALE      {cmd}  <- points at another copy")
                ok = False
            else:
                print(f"  {event:<18} ok")
    sys.exit(0 if ok else 1)

# install / uninstall both start by removing our existing entries. For install
# that is what makes it idempotent and self-repairing: a stale or duplicated
# path is cleared out before the correct one is written.
removed = strip_ours(hooks)

if mode == "install":
    for event, matcher in events:
        block = {"hooks": [{"type": "command", "command": f"{prefix}{hook_script} {event}"}]}
        if matcher:
            block = {"matcher": matcher, **block}
        hooks.setdefault(event, []).append(block)

if hooks:
    data["hooks"] = hooks
else:
    data.pop("hooks", None)

if existed:
    backup = f"{settings_path}.bak.{time.strftime('%Y%m%d%H%M%S')}"
    shutil.copy2(settings_path, backup)
    print(f"backup:  {backup}")

write(settings_path, data)

if mode == "install":
    print(f"installed {len(events)} hooks -> {hook_script}")
    if removed:
        print(f"replaced {removed} existing entr{'y' if removed == 1 else 'ies'}")
else:
    print(f"removed {removed} entr{'y' if removed == 1 else 'ies'}")
PY
}

# Second argument selects the agent; omitted means all of them.
resolve_targets() {
    case "${1:-all}" in
        all) printf '%s' "$TARGETS" ;;
        claude|codex|devin) printf '%s' "$1" ;;
        *) die "unknown target: $1 (expected one of: $TARGETS, or all)" ;;
    esac
}

cmd="${1:-}"

QUIET=0
if [ "${2:-}" = "-q" ] || [ "${2:-}" = "--quiet" ]; then
    QUIET=1
    shift
fi

targets="$(resolve_targets "${2:-all}")"
rc=0

# Targets whose CLI is on PATH and whose hooks are not already correct. Both
# the nudge and the auto-install read this: if it is empty there is nothing to
# do, so neither writes anything. That is what keeps a config reload from
# rewriting settings files it does not need to touch.
list_pending() {
    local t
    for t in $TARGETS; do
        command -v "$(target_binary "$t")" >/dev/null 2>&1 || continue
        [ -x "$(target_hook "$t")" ] || continue
        run_python status "$t" >/dev/null 2>&1 || printf '%s\n' "$t"
    done
}

case "$cmd" in
    install)
        require_python
        for t in $targets; do
            hook="$(target_hook "$t")"
            # Skip rather than fail: installing "all" on a machine that only
            # uses one agent should not be an error.
            if [ ! -x "$hook" ]; then
                printf '%s: skipped (hook script missing: %s)\n' "$t" "$hook"
                continue
            fi
            printf '\n== %s ==\n' "$t"
            run_python install "$t" || rc=1
        done
        ;;
    uninstall)
        require_python
        for t in $targets; do
            printf '\n== %s ==\n' "$t"
            run_python uninstall "$t" || rc=1
        done
        ;;
    status)
        require_python
        for t in $targets; do
            if [ "$QUIET" -eq 1 ]; then
                run_python status "$t" >/dev/null 2>&1 || rc=1
            else
                printf '\n== %s ==\n' "$t"
                run_python status "$t" || rc=1
            fi
        done
        ;;
    pending)
        require_python
        list_pending
        ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command: $cmd" ;;
esac

exit "$rc"
