# CLAUDE.md

Notes for working on this repo. The second half is the important part: a list of
traps that have already cost real debugging time. Add to it when you find a new
one — that is what this file is for.

## What this is

A tmux plugin that tracks AI coding agents (Claude Code, Codex, Devin) and shows
their state in a sidebar pane, a switcher popup, and optionally the status line.

Agent state is **pushed by hooks**, not polled. Each agent's hook writes a status
file; the plugin reads those. Process scanning exists as a fallback for agents
without hooks, but hooks are the design.

## Architecture

```
agent hooks ──write──> ~/.cache/tmux-agent-status/*.status
                                  │
                        sidebar-collector.sh   (one, server-wide)
                                  │ writes cache + signals clients
                                  ▼
                        sidebar.sh             (renderer, one per sidebar pane)
```

- **`scripts/sidebar-collector.sh`** — the only always-on process. Singleton,
  guarded by an atomic hard-link claim. Polls, builds the cache, signals
  renderers over PID files.
- **`scripts/sidebar.sh`** — the renderer. ~1370 lines of bash event loop. One
  process per sidebar pane, so *how many sidebars exist is the dominant cost*.
- **`scripts/lib/`** — sourced helpers. `collect.sh` (data), `session-status.sh`
  (paths/state), `sidebar-clients.sh` (signalling), `selection-targets.sh`
  (jump/selection logic).
- **`hooks/`** — per-agent hook scripts. `scripts/hooks.sh` installs/removes them.
- **`tmux-agent-status.tmux`** — the entrypoint tpm runs. Registers hooks and
  keybindings.

### Sidebar placement

A sidebar is a pane, and a pane belongs to exactly one window. Everything about
placement follows from that:

| mode | processes | where it is |
|---|---|---|
| per-session (default) | one per session | only the window it was opened in |
| `@agent-sidebar-per-window "on"` | **one per window** | everywhere |
| `@agent-sidebar-follow "on"` | **one, total** | wherever you are |

## Conventions

- **Always add tests.** `tests/*.sh`, one file per behaviour, plain bash with a
  `check <desc> <expected> <actual>` helper.
- **Mutation-test new tests.** Break the code deliberately and confirm the test
  fails. Several tests here have passed for the wrong reason; see the traps.
- **Tests must redirect `HOME`.** A test that shells out to `hooks.sh` without it
  will write to the real `~/.claude/settings.json`. This has happened.
- **Tests get their own tmux server** on a private socket (`tmux -L <socket>`),
  never the user's.
- **Measure, do not assert.** Performance claims need `tests/bench.sh`.

## Traps

### tmux

**`window-layout-changed` is not a tmux hook.** It is not in `show-hooks -g`, and
`set-hook -g window-layout-changed ...` is accepted without error — so it looks
registered and silently never fires. Use `after-split-window`, `after-kill-pane`,
`after-resize-window`, `after-select-layout`, `client-resized`.
*`tmux-agent-status.tmux` still registers it for the collector. That hook has
never fired.*

**`display-message -t "session:99"` does not fail on a window that does not
exist.** It silently returns the session's *current* window. Validate by
comparing the requested index against `#{window_index}` of what came back.

**Hooks registered by a previous plugin load persist.** `add_hook_once` cannot
un-register by declining to register — a hook set by an earlier load keeps
firing. Guards belong in the script the hook calls, not in the registration.

**`session-created` fires once per session, effectively simultaneously.** On a
server with fifteen sessions, fifteen handlers run inside the same half second.
Any check-then-act in one of them is a race. Claim with `ln` (atomic, fails if
the target exists), as `sidebar-collector.sh` does in `_claim()`.

**Panes are not pinned.** When a pane opens or closes, tmux reflows every pane in
the window — a sidebar created at 42 columns becomes a third of the window.
Re-assert width on the reflow events above.

**`resize-pane -x` is a no-op on a vertically stacked pane.** It has no width of
its own to change. Tests that build a pane with a bare `split-window` and then
resize it are asserting against a width they never set.

**`join-pane` moves the process with the pane**, and the pane id survives. That
is what makes follow mode possible without restarting the renderer. `-d` keeps
focus where it was; `-f` makes the pane span the full window.

**`base-index` defaults to 0.** A test server started with `-f /dev/null` has
windows 0..N-1. Naming `s1:3` in a three-window session hits the fallback above
and silently tests something else.

**A sidebar pane's stdout *is* the pane.** Any stray output — a shell error, a
debug `echo` — is printed into the UI, twice a second. A `local` outside a
function did exactly this.

### bash

**macOS `/bin/bash` is 3.2.** The libs require bash 4. Anything with
`#!/usr/bin/env bash` may get 3.2 on a contributor's Mac. `declare -A` and
`declare -g` do not exist there. `scripts/lib/require-bash4.sh` handles it for
the plugin; tests must pick a bash 4 interpreter explicitly.

**`$$` is not updated in subshells.** In `( ... ) &`, `$$` is still the parent's
pid. `$BASHPID` is the right one, and does not exist on 3.2.

### Measurement

**`ps %cpu` is a lifetime average.** A process spawned a minute ago reads high
for minutes regardless of what it is doing now. Take the delta of cumulative CPU
time over a window instead.

**Live-server measurement is unfalsifiable here.** The number of working agents
drives almost all the cost and changes minute to minute, so two runs of the same
code differ by more than whatever is being evaluated. Use `tests/bench.sh`, which
builds a fixed world on a private socket with a set number of agents pinned to
`working`.

**Count every process the change introduces.** `bench.sh` originally summed only
`sidebar.sh` and `sidebar-collector.sh`, which understated any change that adds
an `fswatch`, a socket server, or a display proxy — exactly the changes under
evaluation.

**Compare against a spread, not a single number.** If the difference is smaller
than the trial-to-trial spread, there is no difference.

### git

**Squash-merged branches look unmerged to git.** `git branch -d` will refuse
them. Check the PR state before concluding work is unmerged, and before using
`-D`.

## Known dead code

- The `window-layout-changed` hook for the collector (see above) — never fires.
