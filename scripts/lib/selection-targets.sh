#!/usr/bin/env bash

# Shared selection helpers for sidebar and popup switcher targets.

[[ -n "${_SELECTION_TARGETS_LOADED:-}" ]] && return 0
_SELECTION_TARGETS_LOADED=1

selection_scope() {
    local sel_name="$1"
    local sel_type="$2"

    case "$sel_type" in
        S|W)
            echo "session"
            ;;
        P)
            local target="${sel_name#*:}"
            if [[ "$target" == w* ]]; then
                echo "window"
            else
                echo "pane"
            fi
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

selection_session() {
    local sel_name="$1"
    local sel_type="$2"

    case "$sel_type" in
        P)
            echo "${sel_name%%:*}"
            ;;
        *)
            echo "$sel_name"
            ;;
    esac
}

selection_token() {
    local sel_name="$1"
    local sel_type="$2"

    if [[ "$sel_type" == "P" ]]; then
        echo "${sel_name#*:}"
    else
        echo "$sel_name"
    fi
}

selection_window_index() {
    local sel_name="$1"
    local sel_type="$2"
    local scope token
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    token=$(selection_token "$sel_name" "$sel_type")

    case "$scope" in
        window)
            echo "${token#w}"
            ;;
        pane)
            tmux display-message -p -t "$token" "#{window_index}" 2>/dev/null
            ;;
        session)
            tmux display-message -p -t "$(selection_session "$sel_name" "$sel_type")" "#{window_index}" 2>/dev/null
            ;;
    esac
}

selection_tmux_target() {
    local sel_name="$1"
    local sel_type="$2"
    local scope token session
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    token=$(selection_token "$sel_name" "$sel_type")
    session=$(selection_session "$sel_name" "$sel_type")

    case "$scope" in
        session)
            echo "$session"
            ;;
        window)
            echo "${session}:${token#w}"
            ;;
        pane)
            echo "$token"
            ;;
    esac
}

selection_requires_confirmation() {
    # Customized: close sessions/windows/panes immediately without a
    # confirmation prompt. Original behavior asked to confirm for any
    # non-pane scope: [ "$scope" != "pane" ].
    return 1
}

selection_label() {
    local sel_name="$1"
    local sel_type="$2"
    local scope session token window_index window_name
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    session=$(selection_session "$sel_name" "$sel_type")
    token=$(selection_token "$sel_name" "$sel_type")

    case "$scope" in
        session)
            printf 'session %s' "$session"
            ;;
        window)
            window_index="${token#w}"
            window_name=$(tmux display-message -p -t "${session}:${window_index}" "#{window_name}" 2>/dev/null || true)
            if [ -n "$window_name" ]; then
                printf 'window %s:%s (%s)' "$session" "$window_index" "$window_name"
            else
                printf 'window %s:%s' "$session" "$window_index"
            fi
            ;;
        pane)
            window_index=$(tmux display-message -p -t "$token" "#{window_index}" 2>/dev/null || true)
            if [ -n "$window_index" ]; then
                printf 'pane %s in %s:%s' "$token" "$session" "$window_index"
            else
                printf 'pane %s' "$token"
            fi
            ;;
    esac
}

selection_close_prompt() {
    local sel_name="$1"
    local sel_type="$2"
    local scope label
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    label=$(selection_label "$sel_name" "$sel_type")

    case "$scope" in
        session)
            printf 'Close %s and all child windows and panes?' "$label"
            ;;
        window)
            printf 'Close %s and all child panes?' "$label"
            ;;
        pane)
            printf 'Close %s?' "$label"
            ;;
    esac
}

selection_list_panes() {
    local sel_name="$1"
    local sel_type="$2"
    local scope session token
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    session=$(selection_session "$sel_name" "$sel_type")
    token=$(selection_token "$sel_name" "$sel_type")

    case "$scope" in
        session)
            tmux list-panes -t "$session" -F "#{pane_id}" 2>/dev/null
            ;;
        window)
            tmux list-panes -t "${session}:${token#w}" -F "#{pane_id}" 2>/dev/null
            ;;
        pane)
            printf '%s\n' "$token"
            ;;
    esac
}

selection_includes_current_client() {
    local sel_name="$1"
    local sel_type="$2"
    local scope session token
    local current_session current_window current_pane

    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    session=$(selection_session "$sel_name" "$sel_type")
    token=$(selection_token "$sel_name" "$sel_type")
    current_session=$(tmux display-message -p "#{client_session}" 2>/dev/null || true)
    current_window=$(tmux display-message -p "#{window_index}" 2>/dev/null || true)
    current_pane=$(tmux display-message -p "#{pane_id}" 2>/dev/null || true)

    case "$scope" in
        session)
            [ "$session" = "$current_session" ]
            ;;
        window)
            [ "$session" = "$current_session" ] && [ "${token#w}" = "$current_window" ]
            ;;
        pane)
            [ "$token" = "$current_pane" ]
            ;;
        *)
            return 1
            ;;
    esac
}

selection_switch_client() {
    local sel_name="$1"
    local sel_type="$2"
    local scope session token win_idx
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    session=$(selection_session "$sel_name" "$sel_type")
    token=$(selection_token "$sel_name" "$sel_type")

    # Follow mode moves the sidebar to the destination before the switch, so it
    # is already in place on arrival. A no-op unless @agent-sidebar-follow is on.
    case "$scope" in
        pane)
            win_idx=$(tmux display-message -t "$token" -p "#{window_index}" 2>/dev/null || true)
            [ -n "$win_idx" ] && sidebar_follow_to_window "${session}:${win_idx}"
            tmux switch-client -t "$session" 2>/dev/null
            [ -n "$win_idx" ] && tmux select-window -t "${session}:${win_idx}" 2>/dev/null
            tmux select-pane -t "$token" 2>/dev/null
            ;;
        window)
            sidebar_follow_to_window "${session}:${token#w}"
            tmux switch-client -t "$session" 2>/dev/null
            tmux select-window -t "${session}:${token#w}" 2>/dev/null
            ;;
        session)
            sidebar_follow_to_window "$session"
            tmux switch-client -t "$session" 2>/dev/null
            ;;
    esac
}

# ─── Follow mode (@agent-sidebar-follow) ──────────────────────────
# A sidebar is a pane and a pane belongs to exactly one window, so covering
# every window costs a renderer per window, while one-per-session leaves the
# sidebar stranded in whichever window it was opened in. Follow mode keeps a
# single sidebar and moves it to wherever you jump.
#
# join-pane moves the pane *and the process inside it*, and a pane id is stable
# across the move -- so the renderer never restarts, and sidebar client tracking
# (which is keyed by pane id) stays valid. sidebar.sh needs no changes either:
# it re-reads #{client_session} every cycle, so it renders the destination's
# tree on its own once moved.
sidebar_follow_enabled() {
    case "$(tmux show-option -gqv "@agent-sidebar-follow" 2>/dev/null)" in
        1|on|true|yes) return 0 ;;
        *)             return 1 ;;
    esac
}

_window_has_sidebar() {
    local title="${SIDEBAR_TITLE:-agent-sidebar}"
    tmux list-panes -t "$1" -F '#{pane_title}' 2>/dev/null | grep -qxF "$title"
}

# "<pane_id> <window_id>" for the single sidebar, wherever it currently lives.
#
# Global on purpose: under follow mode the per-session auto-create is disabled,
# so exactly one sidebar exists and it follows you across sessions as well as
# windows. (While several exist -- a config reload before the old ones are
# closed -- the destination-occupied guard keeps them from stacking.)
_sidebar_pane_location() {
    local title="${SIDEBAR_TITLE:-agent-sidebar}" pid wid ptitle
    while read -r pid wid ptitle; do
        if [ "$ptitle" = "$title" ]; then
            printf '%s %s' "$pid" "$wid"
            return 0
        fi
    done < <(tmux list-panes -a -F '#{pane_id} #{window_id} #{pane_title}' 2>/dev/null)
    return 1
}

# Move the sidebar into the window that is about to be selected. A no-op when
# follow is off, when there is no sidebar, or when the jump stays inside the
# window the sidebar is already in -- moving between panes of one window is not
# a window switch.
sidebar_follow_to_window() {
    local dest="$1"
    [ -n "$dest" ] || return 0
    sidebar_follow_enabled || return 0

    local found pane src_win dest_win width leftmost
    found=$(_sidebar_pane_location) || return 0
    pane="${found%% *}"
    src_win="${found##* }"

    # tmux does NOT fail on a window target that does not exist: it silently
    # falls back to the session's current window. Without this check, jumping to
    # a window that has since closed would drag the sidebar into whatever window
    # happens to be current instead of doing nothing. A bare session target has
    # no index, and there resolving to the current window is the intent.
    if [ "${dest}" != "${dest%:*}" ]; then
        local want_idx have_idx
        want_idx="${dest##*:}"
        have_idx=$(tmux display-message -t "$dest" -p '#{window_index}' 2>/dev/null || true)
        [ "$want_idx" = "$have_idx" ] || return 0
    fi

    dest_win=$(tmux display-message -t "$dest" -p '#{window_id}' 2>/dev/null) || return 0
    [ -n "$dest_win" ] || return 0
    [ "$src_win" = "$dest_win" ] && return 0

    # The destination may already have its own sidebar -- the session-created
    # hook makes one per session, so this is the common case, not an edge one.
    # Joining ours in anyway would leave two sidebars stacked in one window,
    # each rendering the same tree. The destination is already covered, so
    # leave both where they are.
    if _window_has_sidebar "$dest_win"; then
        return 0
    fi

    # Carry the sidebar's current width rather than re-imposing the configured
    # one. Passing @agent-sidebar-width on every move undoes any manual resize:
    # a sidebar narrowed to 28 columns snapped back to 42 each time you changed
    # window, which reads as the sidebar growing on its own.
    # Always the configured width. Carrying the pane's current width sounds
    # respectful of a manual resize, but tmux nudges pane sizes as layouts
    # change, so each move picks up the drifted value and the sidebar wanders --
    # visibly resizing every time you switch window. A fixed width is the
    # predictable behaviour.
    width=$(tmux show-option -gqv "@agent-sidebar-width" 2>/dev/null)
    [ -z "$width" ] && width=42

    # A zoomed destination has no free layout to join into: the pane would land
    # inside the hidden layout and reappear only when the zoom is dropped.
    if [ "$(tmux display-message -t "$dest_win" -p '#{window_zoomed_flag}' 2>/dev/null)" = "1" ]; then
        tmux resize-pane -t "$dest_win" -Z 2>/dev/null || true
    fi

    leftmost=$(tmux list-panes -t "$dest_win" -F '#{pane_left} #{pane_id}' 2>/dev/null \
        | sort -n | head -1 | awk '{print $2}')
    [ -n "$leftmost" ] || return 0

    # -f full window height, -b to the left, -d so focus stays with the caller's
    # target rather than jumping into the sidebar.
    tmux join-pane -bhfd -l "$width" -s "$pane" -t "$leftmost" 2>/dev/null || true
}
