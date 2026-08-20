# tmux-agent-status

Sidebar-first AI agent session manager for tmux. It keeps a persistent status sidebar wherever you want it -- per session, per window, or a single one that follows you -- adds a hierarchical `fzf` target switcher for fast jumps and cleanup across agent sessions, windows, and panes, and can optionally keep a compact summary in the status line.

Claude Code and Codex CLI are both integrated through hooks, so their states come from agent lifecycle events rather than fragile process polling. Custom agents can still integrate through status files or collector extensions.

## Features

- Persistent status sidebar, in one of three placements: one per session (default),
  one per window (`@agent-sidebar-per-window`), or a single sidebar that follows your
  jumps (`@agent-sidebar-follow`) for one renderer process in total
- Hierarchical `fzf` target switcher for quick jumps and close actions
- Hook-based Claude Code and Codex tracking
- Wait and park modes for triaging work
- Optional compact status-line summary (`@agent-status-line`) and finish sounds (`@agent-sound`), both off by default
- Works across multi-pane sessions, worktrees, and remote tmux sessions

## Supported Agents

| Agent | Integration | Status |
|-------|-------------|--------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | Hook-based via `hooks/better-hook.sh` | Stable |
| [Codex CLI](https://github.com/openai/codex) | Hook-based via `hooks/codex-hook.sh` | Stable in plugin, hooks still experimental upstream |
| [Devin CLI](https://docs.devin.ai/cli) | Hook-based via `hooks/devin-hook.sh` (local CLI only) | Stable in plugin |
| Custom (Aider, Cline, Copilot CLI, etc.) | Status files or collector extensions | Stable |

All agent sessions can run simultaneously across tmux sessions and panes, each tracked independently.

## Install

With [TPM](https://github.com/tmux-plugins/tpm):

```bash
set -g @plugin 'jcapona/tmux-agent-status'
```

Then press `prefix + I` to install.

On macOS, install a modern Bash before using the sidebar:

```bash
brew install bash
```

The plugin auto-detects Homebrew Bash at `/opt/homebrew/bin/bash` or `/usr/local/bin/bash` when macOS launches scripts with the system Bash 3.2.
If Bash is installed somewhere else, set `TMUX_AGENT_STATUS_BASH` to that path.

By default the plugin:

- Starts the sidebar collector daemon
- Auto-creates a sidebar in existing and new tmux sessions
- Binds the popup switcher, wait, park, and next-ready actions

## Agent hooks

Agent state comes from hooks -- each agent reports its own lifecycle events, so
`working`, `done` and `ask` reflect what the agent is really doing instead of
being inferred from process or screen activity.

Install them with:

```bash
~/.tmux/plugins/tmux-agent-status/scripts/hooks.sh install
```

and check them at any time with `scripts/hooks.sh status`.

If an agent's CLI is installed but its hooks are missing or broken, the plugin
says so once on load rather than leaving you with a sidebar that never updates.
Set `@agent-auto-install-hooks "on"` to have it install them instead of asking.
See [HOOKS.md](HOOKS.md) for what that writes, per-agent details, and manual setup.

## Custom Agent Integration

Integrate any AI coding tool with either of these approaches:

1. Write `working`, `done`, or `wait` to `~/.cache/tmux-agent-status/<session>.status`
2. For pane-level parking or per-pane state, write to `~/.cache/tmux-agent-status/panes/<session>_<pane>.status` and `~/.cache/tmux-agent-status/parked/<session>_<pane>.parked`
3. Extend the collector scan in [`scripts/lib/collect.sh`](scripts/lib/collect.sh) if you want automatic process-based tracking

## Usage

Default mode is sidebar-first:

- Every tmux session gets a sidebar pane automatically (not under
  `@agent-sidebar-follow`, where a single sidebar is opened once and then follows you)
- `prefix + S` opens the hierarchical `fzf` target switcher
- `prefix + O` toggles the sidebar in the current window (opens it, or closes it when
  already visible). Under `@agent-sidebar-follow` it also summons the single sidebar
  here when it is in another window

| Key | Action |
|-----|--------|
| `prefix + S` | Open the hierarchical `fzf` target switcher |
| `prefix + O` | Toggle the sidebar: opens it, closes it when already visible, or summons it here under follow mode |
| `prefix + N` | Jump to the next inbox item in inbox order |
| `prefix + W` | Put the current session or pane into timed wait mode |
| `prefix + P` | Park the current session or pane for later |

With `@agent-status-line "on"`, the status bar shows one glyph per agent. The
glyph identifies the agent, the colour identifies its status:

| Agent | Glyph |
|-------|-------|
| Claude | `✳` |
| Codex | `⬢` |
| Devin | `◆` |
| Other | `●` |

| Status | Colour |
|--------|--------|
| working | yellow, pulsing (`✳`/`✻`, `⬢`/`⬡`, …) |
| waiting | cyan |
| ask | magenta |
| done | green |

For example two Claude agents working alongside a finished Codex agent
renders as two yellow Claude glyphs next to a green `⬢`. Each working
glyph flips frames every second, staggered by position (`✳ ✻` one second,
`✻ ✳` the next) so a row of busy agents pulses rather than blinking in
unison. Glyphs and colours are defined in
[`scripts/lib/status-summary.sh`](scripts/lib/status-summary.sh) if you want
different ones.

Parked sessions stay visible in the sidebar and switcher, but are excluded from the status-line summary when it is enabled.

Inside the popup switcher:

- `Enter` switches to the selected session, window, or pane
- `Tab` expands or collapses the selected session or window
- `Ctrl-X` closes the selected pane immediately
- `Ctrl-X` on a window immediately closes that window and all child panes
- `Ctrl-X` on a session immediately closes that session and all child windows and panes
- `Ctrl-P` parks or unparks the selected session, window, or pane
- `Ctrl-W` opens wait mode for the selected target, or cancels an existing wait
- `Ctrl-R` resets tracked state

Inside the sidebar:

- `x`, `p`, and `w` perform the same close, park, and wait actions without interfering with popup search input
- `m` toggles between tree and agents view (rebind with `@agent-sidebar-mode-key`)

`prefix + N` follows the same top-to-bottom order as the `INBOX` section. The inbox is ordered by session name, then by tmux window order within each session.

Parking, waiting, and closing always apply to the selected scope only:

- selecting a session row affects the whole session
- selecting a window row affects only that window
- selecting a pane row affects only that pane

In multi-window sessions, sidebar and inbox rows labeled with a window name operate on that window, not just the first pane inside it.

## Configuration

```tmux
set -g @agent-status-key "S"
set -g @agent-sidebar-key "O"
set -g @agent-next-done-key "N"
set -g @agent-wait-key "W"
set -g @agent-park-key "P"

# Compact glyph summary in tmux's status line. Off by default: the sidebar and
# the switcher already show agent state, and status-right is usually already
# spent on other modules. Turning it on also sets status-interval to 1 so the
# glyphs animate; turning it back off removes the module on the next config
# reload, but leaves status-interval where it is.
set -g @agent-status-line "off"            # off | on

set -g @agent-switcher-style "both"        # popup | sidebar | both
set -g @agent-status-display-method "popup" # popup | window
# Sidebar width. Re-asserted whenever a window is reflowed (a pane opening or
# closing redistributes every pane in the window), so the sidebar keeps this
# width instead of drifting to whatever share the layout gives it. Ignored for
# a window too narrow to give it without squeezing everything else.
#
# Note that this makes the option authoritative: resizing the sidebar by hand
# holds until the next time a pane opens or closes in that window, at which
# point it returns to this width. Set the option rather than dragging the
# border if you want a different width to stick.
set -g @agent-sidebar-width "42"

# A sidebar is a pane, so it lives in exactly one window. Off (the default) runs
# one renderer per session, which means it is only in the window it was opened
# in. Set "on" for one sidebar per window, at the cost of a renderer process per
# window. See @agent-sidebar-follow below for the third option: exactly one
# sidebar that moves to wherever you are.
set -g @agent-sidebar-per-window "off"     # off | on

# Follow mode: exactly one sidebar for the whole server, which moves to the
# window you jump to -- across sessions as well as windows. The pane is moved
# with join-pane, so the renderer is carried along rather than restarted, and
# one process covers everything. Jumps between panes of the same window do
# nothing.
#
#   on      follow jumps made through the sidebar or the switcher -- pressing
#           Enter on a row takes the sidebar with you. A plain window change
#           (prefix+n, prefix+<digit>, the window list) leaves it where it is.
#   always  also follow plain window changes, so the sidebar is wherever you
#           are no matter how you got there.
#
# Follow mode owns placement, so it disables the per-session auto-create: open
# the sidebar once (prefix + O) and it follows from then on. prefix + O also
# summons it from another window, and still closes it when it is already here.
# This makes @agent-sidebar-per-window irrelevant.
set -g @agent-sidebar-follow "off"         # off | on | always

# By default only windows containing a recognised agent are listed. On also
# lists windows with no agent (shown with a dim dot), and orders windows by
# window index rather than by whichever agent was found first.
set -g @agent-show-all-windows "off"       # off | on

# Totals row at the very top of the sidebar (working / done / waiting across
# every session). Off by default -- the same counts appear per session in the
# tree below, and the row costs a line of an already narrow pane.
set -g @agent-sidebar-header "off"         # off | on

# Install missing agent hooks on load instead of only reporting them. Nothing
# is written when the hooks are already correct, so this does not rewrite agent
# config files every time tmux reloads.
set -g @agent-auto-install-hooks "off"     # off | on

# Switcher view (prefix + S). "tree" is the hierarchical
# session/window/pane list (default). "agents" is a flat list of every
# agent pane sorted by status. Toggle mid-session with ctrl-f.
set -g @agent-switcher-default-mode "tree"  # tree | agents

# Key, pressed inside the sidebar pane, that toggles it between tree and
# agents view.
set -g @agent-sidebar-mode-key "m"

# Master switch for audible notifications. Off by default; the options below
# only take effect once this is on.
set -g @agent-sound "off"                  # off | on

# Sound played when an agent moves into the `ask` state. Same values as
# @agent-notification-sound.
set -g @agent-ask-sound "Funk"
```

`@agent-switcher-style "both"` is the default. It keeps the persistent sidebar and leaves `prefix + S` as the lightweight popup switcher.

The switcher popup has two views. **Tree** (default) is the hierarchical session/window/pane list; tab expands/collapses. **Agents** is a flat list of every agent pane (any status) sorted by priority — `ask`, `done`, `working`, `wait`, `parked` — with a live preview pane and 2-second refresh. Press `ctrl-f` inside the popup to toggle between views.

Within a session the sidebar lists its windows, each prefixed by its tmux window index; the current window has its index bracketed and highlighted. Every window holding an agent expands to show those agent panes beneath it, including a window with only one — a row therefore always says whether it is a window or an agent, rather than a lone agent borrowing its window's name. Windows with no agent appear only when `@agent-show-all-windows` is on.

The sidebar has the same two views, toggled with `m` from inside the sidebar pane (alongside `w`/`p`/`x` for wait/park/close). In **tree** mode the SESSIONS section lists every session and collapses single-agent sessions to one row; the INBOX section surfaces `done`/`ask` work. In **agents** mode the SESSIONS section is filtered to sessions/worktrees that contain agent panes and every agent pane is expanded; INBOX is suppressed because it would duplicate the same rows.

## Notification Sounds

Sound is off by default. Turn it on with:

```tmux
set -g @agent-sound "on"                   # off | on
```

Then choose which sound plays when an agent finishes:

```tmux
set -g @agent-notification-sound "chime"
```

Options: `chime` (default), `bell`, `fanfare`, `frog`, `speech`, `none`.

`@agent-sound` is the master switch: with it off nothing plays regardless of the
options above. `none` mutes a single event while leaving the other enabled.

## Multi-Agent Deploy

Launch parallel AI coding sessions with isolated git worktrees:

```bash
bash ~/.tmux/plugins/tmux-agent-status/scripts/deploy-sessions.sh manifest.json
```

Each session gets a `deploy/<name>` branch, and the plugin tracks the spawned sessions automatically.

## SSH Remote Sessions

Monitor AI agents on remote machines:

```bash
./setup-server.sh <session-name> <ssh-host>
```

Works with cloud VMs, GPU boxes, and any SSH-accessible tmux host.

## How It Works

```text
┌──────────────┐    hooks     ┌──────────────────────────┐
│ Claude Code  ├─────────────►│ ~/.cache/tmux-agent-     │
└──────────────┘              │ status/                  │
                              │ <session>.status         │
┌──────────────┐    hooks     │ panes/*.status           │
│ Codex CLI    ├─────────────►│ wait/*.wait              │
└──────────────┘              │ parked/*.parked          │
                              └─────────────┬────────────┘
┌──────────────┐ status files               │
│ Custom agent ├────────────────────────────┘
└──────────────┘
                                            ▼
                              ┌──────────────────────────┐
                              │ sidebar-collector.sh     │
                              │ writes shared cache and  │
                              │ status summary           │
                              └─────────────┬────────────┘
                                            │
                         ┌──────────────────┼──────────────────┐
                         ▼                  ▼                  ▼
                 ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
                 │ sidebar pane │   │ status line  │   │ fzf switcher │
                 └──────────────┘   └──────────────┘   └──────────────┘
                                    status line is opt-in
```

- Claude Code support is hook-based
- Codex CLI support is hook-based
- Custom agents can be file-based or process-detected
- The sidebar is the main live view; the `fzf` switcher is the quick jump and close tool

## Credits

Forked from [samleeney/tmux-agent-status](https://github.com/samleeney/tmux-agent-status),
which is where the sidebar, the collector daemon and the hook-based agent
tracking came from. This fork has since diverged: the sidebar tree was reworked,
several defaults changed, and the status line, per-window sidebars and
all-window listing became options.

## License

MIT
