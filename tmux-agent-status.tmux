#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default key bindings
default_switcher_key="S"
default_next_done_key="N"
default_wait_key="W"
# Uppercase throughout: tmux binds `p` to previous-window and `o` to
# select-pane by default, and a plugin silently taking those over is a
# surprise every user has to undo by hand.
default_park_key="P"

# Get user configuration or use defaults.
switcher_key=$(tmux show-option -gqv "@agent-status-key")
next_done_key=$(tmux show-option -gqv "@agent-next-done-key")
wait_key=$(tmux show-option -gqv "@agent-wait-key")
park_key=$(tmux show-option -gqv "@agent-park-key")

[ -z "$switcher_key" ] && switcher_key="$default_switcher_key"
[ -z "$next_done_key" ] && next_done_key="$default_next_done_key"
[ -z "$wait_key" ] && wait_key="$default_wait_key"
[ -z "$park_key" ] && park_key="$default_park_key"

# Default switcher view: "tree" (hierarchical session/window/pane, default)
# or "agents" (flat list of every agent pane). Toggle mid-session with ctrl-f.
switcher_default_mode=$(tmux show-option -gqv "@agent-switcher-default-mode")
case "$switcher_default_mode" in
    tree|agents) ;;
    *) switcher_default_mode="tree" ;;
esac

# Switcher style: "popup" (fzf only), "sidebar" (sidebar only), or "both" (default)
switcher_style=$(tmux show-option -gqv "@agent-switcher-style")
[ -z "$switcher_style" ] && switcher_style="both"

# Display method: "popup" (default, requires tmux 3.2+) or "window" (fallback)
display_method=$(tmux show-option -gqv "@agent-status-display-method")
[ -z "$display_method" ] && display_method="popup"

# Sidebar key (used in "both" mode; in "sidebar" mode the main switcher key is used)
sidebar_key=$(tmux show-option -gqv "@agent-sidebar-key")
[ -z "$sidebar_key" ] && sidebar_key="O"

# Helper to bind the fzf switcher using the configured display method.
# Passes the default mode through via TMUX_AGENT_SWITCHER_MODE so the
# script can pick the right initial view without an extra CLI flag.
bind_fzf_switcher() {
    local key="$1"
    local launch
    case "$display_method" in
        "window")
            printf -v launch 'env TMUX_AGENT_SWITCHER_MODE=%q %q' \
                "$switcher_default_mode" "$CURRENT_DIR/scripts/hook-based-switcher.sh"
            tmux bind-key "$key" new-window -n "agent-status" "$launch"
            ;;
        "popup"|*)
            # Popup geometry varies by mode + preview state, so the popup
            # loop wrapper owns the display-popup invocation and relaunches
            # with new dimensions when the inner script requests it.
            printf -v launch 'env TMUX_AGENT_SWITCHER_MODE=%q %q' \
                "$switcher_default_mode" "$CURRENT_DIR/scripts/switcher-popup-loop.sh"
            tmux bind-key "$key" run-shell -b "$launch"
            ;;
    esac
}

case "$switcher_style" in
    popup)
        bind_fzf_switcher "$switcher_key"
        ;;
    sidebar)
        tmux bind-key "$switcher_key" run-shell "$CURRENT_DIR/scripts/sidebar-toggle.sh --toggle"
        ;;
    both|*)
        bind_fzf_switcher "$switcher_key"
        tmux bind-key "$sidebar_key" run-shell "$CURRENT_DIR/scripts/sidebar-toggle.sh --toggle"
        ;;
esac

# Set up keybinding to switch to next done project
tmux bind-key "$next_done_key" run-shell "$CURRENT_DIR/scripts/next-done-project.sh"

# Set up keybinding to put session in wait mode
tmux bind-key "$wait_key" run-shell "$CURRENT_DIR/scripts/wait-session.sh"

# Set up keybinding to park a session for later
tmux bind-key "$park_key" run-shell "$CURRENT_DIR/scripts/park-session.sh"

# Detect iTerm2 Control Mode (tmux -CC) and skip status polling / daemons
# to avoid interfering with the control protocol. Keybindings above are fine.
control_mode=$(tmux display-message -p '#{client_control_mode}' 2>/dev/null)
if [ "$control_mode" = "1" ]; then
    exit 0
fi

# ── Status line integration (@agent-status-line) ──────────────────
# Off by default: the sidebar and the fzf switcher already show agent state,
# and the glyph summary competes for room on a status-right that most configs
# have already spent on their own modules. Set @agent-status-line "on" to get
# it back.
#
# status-interval is gated on the same option. Forcing a 1s poll only pays for
# itself when the glyphs are actually being drawn; with the module off it is
# pure overhead, so the user's own interval is left alone.
case "$(tmux show-option -gqv "@agent-status-line")" in
    1|on|true|yes) status_line_enabled=1 ;;
    *)             status_line_enabled=0 ;;
esac

current_status_right=$(tmux show-option -gqv status-right)
if [ "$status_line_enabled" = "1" ]; then
    tmux set-option -g status-interval 1
    if ! echo "$current_status_right" | grep -q "status-line.sh"; then
        tmux set-option -ag status-right " #($CURRENT_DIR/scripts/status-line.sh)"
    fi
elif echo "$current_status_right" | grep -q "status-line.sh"; then
    # Turned off after having been on: strip our module back out so the change
    # takes effect on a config reload instead of needing a server restart.
    tmux set-option -g status-right \
        "$(printf '%s' "$current_status_right" | sed 's| *#([^)]*status-line\.sh[^)]*)||g')"
fi

# Append a hook only when an identical entry is not already registered.
#
# tmux has no idempotent set-hook: `-ga` appends unconditionally, so every
# config reload stacks another copy. Reloading often leaves dozens of duplicates
# (observed: 84 entries on session-created after ~28 reloads, which fired
# daemon-monitor.sh 28 times per new session). Plain `-g` is not an option --
# it replaces the whole array and would silently delete hooks the user or other
# plugins registered on the same event.
#
# Quotes are stripped from both sides before comparing because tmux re-renders
# hook commands with its own quoting, which will not match ours byte for byte.
# Same idea as the status-right guard above.
# tmux silently accepts hook names it does not have: `set-hook -g <nonsense> ...`
# exits 0, prints nothing, and never appears in `show-hooks -g`. A typo or an
# invented name therefore looks registered forever and never fires. Five of
# these had accumulated here. tests/hooks-exist.sh checks every name below
# against what tmux reports.
add_hook_once() {
    local hook="$1" cmd="$2" key
    key=$(printf '%s' "$cmd" | tr -d "\"'")
    if ! tmux show-hooks -g "$hook" 2>/dev/null | tr -d "\"'" | grep -Fq -- "$key"; then
        tmux set-hook -ga "$hook" "$cmd"
    fi
}

# Set up daemon monitor to ensure smart-monitor is always running
# Start daemon monitor on session created
add_hook_once session-created "run-shell '$CURRENT_DIR/scripts/daemon-monitor.sh'"

# Sidebars are event-driven: wake them when tmux client focus changes so they
# can refresh ACTIVE markers without polling in the pane process.
add_hook_once client-attached "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh refresh'"
add_hook_once client-session-changed "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh refresh'"
add_hook_once after-select-pane "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh refresh'"
add_hook_once after-select-window "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh refresh'"
add_hook_once session-window-changed "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh refresh'"

# Nudge the collector when tmux structure or names change so cache rebuilds stay
# event-driven instead of waiting for a fallback poll.
add_hook_once session-created "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh collect'"
# These are the events that actually reflow a window. The block used to hook
# window-layout-changed, which tmux does not have -- see the note above
# add_hook_once for why that is silent rather than an error.
add_hook_once after-split-window "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh collect'"
add_hook_once after-kill-pane "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh collect'"
add_hook_once after-resize-pane "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh collect'"
add_hook_once after-resize-window "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh collect'"
add_hook_once after-select-layout "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh collect'"
add_hook_once after-new-window "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh collect'"
add_hook_once window-unlinked "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh collect'"
add_hook_once after-rename-window "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh collect'"

# ── Sidebar placement (@agent-sidebar-per-window) ─────────────────
# A sidebar is a pane, and a pane belongs to exactly one window, so "a sidebar
# in every session" only ever means "in one window of it" -- switch windows and
# it is gone. Covering every window is therefore one renderer process per
# window. Measured on a fixed workload, 12 renderers cost 2.81% of a core
# against 0.70% for 3 -- so per-session is the cheaper default by roughly 4x.
# Off by default; set "on" to put one in every window.
case "$(tmux show-option -gqv "@agent-sidebar-per-window")" in
    1|on|true|yes) sidebar_per_window=1 ;;
    *)             sidebar_per_window=0 ;;
esac

# Auto-create sidebar in new sessions (small delay so the session is ready).
# The target is passed explicitly: sidebar-toggle.sh falls back to the *current*
# window, which for a session created detached (`new-session -d`, how
# tmux-resurrect restores and how most scripted sessions start) is not in the
# new session at all -- so the sidebar landed in whatever window happened to be
# focused, and the new session silently got none.
add_hook_once session-created "run-shell -b 'sleep 0.5 && $CURRENT_DIR/scripts/sidebar-toggle.sh #{window_id}'"

# after-new-window does not fire for a session's first window, so this covers
# windows 2..n and the session-created hook above covers the first.
if [ "$sidebar_per_window" = "1" ]; then
    add_hook_once after-new-window "run-shell -b '$CURRENT_DIR/scripts/sidebar-toggle.sh #{window_id}'"
fi

# ── Hook configuration (@agent-auto-install-hooks) ────────────────
# State comes from hooks, and a missing hook fails silently -- the agent works,
# its state just never arrives -- so say something rather than let the plugin
# look broken.
#
# hooks.sh pending lists only agents whose CLI is on PATH and whose hooks are
# not already correct. When it is empty nothing happens at all, which is what
# keeps this from rewriting config files on every config reload: tpm re-runs
# this file every time, not just at install.
#
# Off by default, this only prints a hint. Turned on, it installs them. Backgrounded
# so a config reload is never blocked on it.
(
    pending=$("$CURRENT_DIR/scripts/hooks.sh" pending 2>/dev/null || true)
    if [ -n "$pending" ]; then
        case "$(tmux show-option -gqv "@agent-auto-install-hooks")" in
            1|on|true|yes)
                for target in $pending; do
                    "$CURRENT_DIR/scripts/hooks.sh" install "$target" >/dev/null 2>&1 || true
                done
                tmux display-message "tmux-agent-status: installed hooks for $(echo $pending | tr '\n' ' ')"
                ;;
            *)
                tmux display-message \
                    "tmux-agent-status: hooks missing for $(echo $pending | tr '\n' ' ') -- run scripts/hooks.sh install"
                ;;
        esac
    fi
) &

# Start sidebar data collector daemon (one per tmux server)
"$CURRENT_DIR/scripts/sidebar-collector.sh" &

# Also start it now if tmux is already running
if tmux list-sessions >/dev/null 2>&1; then
    "$CURRENT_DIR/scripts/daemon-monitor.sh" >/dev/null 2>&1

    # Backfill anything that has no sidebar yet: every window when per-window
    # is on, otherwise one per session as before. Read line by line so session
    # names containing spaces are not split.
    if [ "$sidebar_per_window" = "1" ]; then
        backfill_list=$(tmux list-windows -a -F '#{window_id}' 2>/dev/null)
    else
        backfill_list=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
    fi
    while IFS= read -r tgt; do
        [ -n "$tgt" ] || continue
        has_sidebar=$(tmux list-panes -t "$tgt" -F '#{pane_title}' 2>/dev/null | grep -c "agent-sidebar")
        if [ "$has_sidebar" -eq 0 ]; then
            # Passed as an argument, not via `run-shell -t`: that flag sets the
            # target for format expansion, not the window the script itself
            # resolves, so the sidebar would go to the active window instead.
            tmux run-shell -b "$(printf '%q %q' "$CURRENT_DIR/scripts/sidebar-toggle.sh" "$tgt")" 2>/dev/null
        fi
    done <<EOF
$backfill_list
EOF
fi
