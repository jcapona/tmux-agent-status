# Agent hooks

State comes from hooks: each agent reports its own lifecycle events, so
`working` / `done` / `ask` reflect what the agent is actually doing rather than
being guessed from process or screen activity. Discovery of *which* panes hold
an agent also falls back to process detection, but state does not.

## Install them for me

```bash
~/.tmux/plugins/tmux-agent-status/scripts/hooks.sh install        # all agents
~/.tmux/plugins/tmux-agent-status/scripts/hooks.sh install claude # just one
```

The path written is derived from the script's own location, so it is correct
however the plugin was installed. Re-running is safe: existing entries for this
plugin are replaced rather than duplicated, which also repairs a path that has
gone stale because the plugin moved.

```bash
scripts/hooks.sh status      # what is configured, and whether it works
scripts/hooks.sh uninstall   # remove only this plugin's entries
```

`status` is the first thing to run when an agent shows no state: a hook whose
path does not exist fails silently, so the agent keeps working and its state
simply never arrives. Agents whose hook script is not present are skipped, not
treated as an error.

Uninstall touches only entries belonging to this plugin. Hooks you or other
tools added to the same events are left alone, and a timestamped backup is
written before any change.

## Setting them up by hand

Everything below is what `hooks.sh install` writes. You only need it if you
would rather manage the files yourself.

## Claude Code

Add hooks to `~/.claude/settings.json`.

The paths below use tpm's default plugin directory, `~/.tmux/plugins`. tpm
installs wherever `TMUX_PLUGIN_MANAGER_PATH` points, so if your tmux config
lives in `~/.config/tmux` you have most likely set it to
`~/.config/tmux/plugins` and the hook paths need to match. Check with:

```bash
tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH   # unset means ~/.tmux/plugins
```

A wrong path fails silently: the agent keeps working, its state simply never
reaches the plugin, which looks like broken tracking rather than a typo.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.tmux/plugins/tmux-agent-status/hooks/better-hook.sh UserPromptSubmit"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.tmux/plugins/tmux-agent-status/hooks/better-hook.sh PreToolUse"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.tmux/plugins/tmux-agent-status/hooks/better-hook.sh Stop"
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.tmux/plugins/tmux-agent-status/hooks/better-hook.sh Notification"
          }
        ]
      }
    ]
  }
}
```

Claude Code state is tracked entirely through hooks, so the plugin gets precise working/done transitions directly from the agent. If a turn ends while a background task is still running (e.g. a `run_in_background` Bash command), the `Stop` payload's `background_tasks` array keeps the session marked `working` until a later `Stop` reports the task finished — so backgrounded work doesn't show a premature green checkmark.

## Codex CLI

tmux-agent-status supports official [Codex hooks](https://developers.openai.com/codex/hooks).

Enable hooks in `~/.codex/config.toml`:

```toml
[features]
hooks = true
```

For a one-off session, you can also start Codex with `codex --enable hooks`.

To enable Codex tracking globally, add `~/.codex/hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.tmux/plugins/tmux-agent-status/hooks/codex-hook.sh SessionStart"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.tmux/plugins/tmux-agent-status/hooks/codex-hook.sh UserPromptSubmit"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.tmux/plugins/tmux-agent-status/hooks/codex-hook.sh PreToolUse"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.tmux/plugins/tmux-agent-status/hooks/codex-hook.sh Stop"
          }
        ]
      }
    ]
  }
}
```

Restart Codex, then run `/hooks` in the CLI and trust the new command hooks if Codex marks them as pending review. Non-managed command hooks must be trusted before Codex will run them.

Codex state is also hook-based. The handler marks the tmux session or pane `working` on `UserPromptSubmit` and `PreToolUse`, resets it to `done` on `Stop`, and seeds resumed sessions on `SessionStart`.

For repo-local tracking while working on this plugin, put the same hook shape in `<repo>/.codex/hooks.json`. Codex loads project-local hooks once the project `.codex/` layer is trusted.

## Devin CLI

This integrates the local [Devin CLI](https://docs.devin.ai/cli) (the `devin` binary that runs in your terminal), not cloud Devin sessions. The Devin CLI uses a [Claude Code-compatible hooks format](https://docs.devin.ai/cli/extensibility/hooks/overview).

Add hooks to `~/.config/devin/config.json`

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.tmux/plugins/tmux-agent-status/hooks/devin-hook.sh SessionStart"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.tmux/plugins/tmux-agent-status/hooks/devin-hook.sh UserPromptSubmit"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.tmux/plugins/tmux-agent-status/hooks/devin-hook.sh PreToolUse"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.tmux/plugins/tmux-agent-status/hooks/devin-hook.sh PostToolUse"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.tmux/plugins/tmux-agent-status/hooks/devin-hook.sh Stop"
          }
        ]
      }
    ]
  }
}
```

Run `/hooks` in the CLI to confirm the command hooks are loaded, and trust them if Devin marks them as pending review.

Devin state is hook-based. The handler marks the session or pane `working` on `UserPromptSubmit`/`PreToolUse`/`PostToolUse`, resets it to `done` on `Stop`, and seeds resumed sessions on `SessionStart`.

Without hooks, the collector still auto-detects a running `devin` process inside a pane (presence only); hooks are required for live `working`/`done` state.
