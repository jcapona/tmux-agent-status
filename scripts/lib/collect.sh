#!/usr/bin/env bash

# Shared data collection logic for the sidebar.
# Sourced by sidebar-collector.sh (daemon) and optionally sidebar.sh (fallback).
#
# Requires the caller to:
#   - source lib/session-status.sh (for STATUS_DIR)
#   - declare global: ENTRIES, SEL_NAMES, SEL_TYPES, PANE_COUNTS (associative),
#     KNOWN_AGENTS (associative), LIVE_PANES (associative), PID_PPID (associative),
#     SESS_START, _COLLECT_TICK, _LAST_STATUS_MTIME
#
# Populates: ENTRIES[], SEL_NAMES[], SEL_TYPES[], PANE_COUNTS[], SESS_START,
#            SUMMARY_WORKING, SUMMARY_DONE, SUMMARY_TOTAL,
#            SUMMARY_HAS_WORKING, SUMMARY_AGENTS[]
# Persists across calls: LIVE_PANES[]
# Sets _COLLECT_CHANGED=1 when data was rebuilt, 0 when skipped (no changes).

[[ -n "${_COLLECT_LIB_LOADED:-}" ]] && return 0
_COLLECT_LIB_LOADED=1

# ─── PID ancestry helpers ─────────────────────────────────────────

_build_pid_map() {
    PID_PPID=()
    while read -r p pp; do
        [ -z "$p" ] && continue
        PID_PPID[$p]="$pp"
    done < <(ps -eo pid=,ppid= 2>/dev/null)
}

# Walk up the process tree from $1 looking for any PID in the
# space-separated set $2.  Returns 0 and prints the matching pane PID.
find_ancestor_pane() {
    local pid="$1"
    local pane_pid_set=" $2 "
    local depth=0
    while (( pid > 1 && depth < 30 )); do
        if [[ "$pane_pid_set" == *" $pid "* ]]; then
            echo "$pid"
            return 0
        fi
        pid="${PID_PPID[$pid]:-}"
        [ -z "$pid" ] && return 1
        ((depth++))
    done
    return 1
}

# ─── State priority ───────────────────────────────────────────────
_state_pri() {
    case "$1" in
        working) echo 5 ;; ask)     echo 3 ;;
        done)    echo 2 ;; *)       echo 0 ;;
    esac
}

# ─── Sidebar mode (tree | agents) ─────────────────────────────────
# Set by sidebar-toggle-mode.sh. In agents mode the SESSIONS section
# only includes sessions/worktrees that have at least one agent pane,
# and every agent pane is expanded (even when a session has just one).
_sidebar_mode() {
    local mode_file="$STATUS_DIR/.sidebar-mode"
    local mode=""
    [ -f "$mode_file" ] && mode=$(<"$mode_file")
    case "$mode" in
        agents) echo agents ;;
        *)      echo tree ;;
    esac
}

# ─── Show every window (@agent-show-all-windows) ──────────────────
# Off by default. When on, an expanded session renders a row for every one of
# its windows, including windows that contain no agent, and windows are ordered
# by window index instead of by whichever agent was enumerated first.
#
# Read per collection cycle rather than cached to a file like _sidebar_mode, so
# the option takes effect on a config reload without restarting the collector.
# One `show-option` is negligible next to the `list-panes -a` each cycle runs.
# The INBOX section is opt-in. prefix+N walks the same rows, so it sets
# INBOX_FORCE before collecting -- turning the section off hides it from the
# sidebar without disabling the jump, which is a separate feature.
_inbox_enabled() {
    (( ${INBOX_FORCE:-0} )) && { echo 1; return; }
    case "$(tmux show-option -gqv "@agent-sidebar-inbox" 2>/dev/null)" in
        1|on|true|yes) echo 1 ;;
        *)             echo 0 ;;
    esac
}

_show_all_windows() {
    case "$(tmux show-option -gqv "@agent-show-all-windows" 2>/dev/null)" in
        1|on|true|yes) echo 1 ;;
        *)             echo 0 ;;
    esac
}

# Minutes of window silence after which a "working" status stops being
# believed. Generous by default: an agent can legitimately spend a long time on
# one step, but it prints *something* while doing so -- a spinner, a tool
# result, a token. Silence for this long means the work ended without a Stop
# hook firing. 0 disables the check and restores pure hook-driven state.
_stale_working_secs() {
    local m
    m="$(tmux show-option -gqv "@agent-stale-working-minutes" 2>/dev/null)"
    case "$m" in
        ''|*[!0-9]*) m=20 ;;
    esac
    echo $(( m * 60 ))
}

# ─── Screen-change tracking for stale "working" ───────────────────
# Persist across collect_data calls: the collector sources this once and loops.
declare -A _SCREEN_HASH=()   # pane key → hash of its visible tail
declare -A _SCREEN_TS=()     # pane key → when that hash last changed
_SCREEN_LAST_SAMPLE=0

# How often to look. Every cycle would mean a capture-pane per working pane per
# second; the question being answered ("has this screen changed in the last
# twenty minutes") does not need that resolution.
_SCREEN_SAMPLE_SECS=10

# Sample the panes that claim to be working, and record when each last changed.
#
# Window activity (#{window_activity}) was tried first and is too coarse: it is
# window-level, so a shell in the same window, or the sidebar being joined in or
# out of it by follow mode, resets the clock and masks a stale pane. Observed
# directly -- a pane whose status file was 903 minutes old sat in a window
# reporting output 1 minute ago.
#
# The pane's own visible text is the per-pane equivalent. An agent that is
# working repaints -- a spinner, a token counter, a tool result; an idle one
# holds a static prompt. Only the tail is hashed, and only for panes that claim
# to be working, so the usual cost is nothing.
_sample_working_screens() {
    local now="$1" pane_dir="$2"; shift 2
    (( now - _SCREEN_LAST_SAMPLE < _SCREEN_SAMPLE_SECS )) && return 0
    _SCREEN_LAST_SAMPLE="$now"

    local key pane h
    for key in "$@"; do
        pane="${key#*:}"
        h=$(tmux capture-pane -p -t "$pane" -S -8 2>/dev/null | cksum 2>/dev/null | awk '{print $1}')
        [ -z "$h" ] && continue
        if [ -z "${_SCREEN_HASH[$key]:-}" ]; then
            # First sight of this pane. Starting its clock at "now" would give
            # every stale pane a fresh grace period on each collector restart --
            # and reloads are frequent, so a status stuck for fifteen hours came
            # back as "working" every time. The status file's mtime is the last
            # moment a hook said anything about this pane, which is a strictly
            # better estimate of when it was last really doing something.
            local _seed_file="$pane_dir/${key%%:*}_${key#*:}.status"
            if [ -f "$_seed_file" ]; then
                # stat -f means "format" on macOS but "filesystem status" on GNU
                # coreutils, where it succeeds and prints block counts -- so a ||
                # fallback silently yields garbage. Branch on the OS instead.
                if [[ "$(uname)" == "Darwin" ]]; then
                    _SCREEN_TS[$key]=$(stat -f %m "$_seed_file" 2>/dev/null || echo "$now")
                else
                    _SCREEN_TS[$key]=$(stat -c %Y "$_seed_file" 2>/dev/null || echo "$now")
                fi
            else
                _SCREEN_TS[$key]="$now"
            fi
            _SCREEN_HASH[$key]="$h"
        elif [ "${_SCREEN_HASH[$key]}" != "$h" ]; then
            _SCREEN_HASH[$key]="$h"
            _SCREEN_TS[$key]="$now"
        fi
    done
}

# ─── Main collection ──────────────────────────────────────────────
collect_data() {

    local SIDEBAR_MODE
    SIDEBAR_MODE=$(_sidebar_mode)

    local SHOW_ALL_WINDOWS
    SHOW_ALL_WINDOWS=$(_show_all_windows)

    # Quick change detection: skip full rebuild if nothing changed.
    (( ++_COLLECT_TICK >= 10 )) && { _COLLECT_TICK=0; _LAST_STATUS_MTIME=""; }
    local cur_mtime
    if [[ "$(uname)" == "Darwin" ]]; then
        cur_mtime=$(stat -f %m "$STATUS_DIR" "$PANE_DIR" "$REFRESH_FILE" 2>/dev/null)
    else
        cur_mtime=$(stat -c %Y "$STATUS_DIR" "$PANE_DIR" "$REFRESH_FILE" 2>/dev/null)
    fi
    if [[ "$cur_mtime" == "$_LAST_STATUS_MTIME" ]]; then
        _COLLECT_CHANGED=0
        return
    fi
    _LAST_STATUS_MTIME="$cur_mtime"
    _COLLECT_CHANGED=1

    ENTRIES=()
    SEL_NAMES=()
    SEL_TYPES=()
    SUMMARY_WORKING=0
    SUMMARY_DONE=0
    SUMMARY_TOTAL=0
    SUMMARY_HAS_WORKING=0
    SUMMARY_AGENTS=()

    local now
    printf -v now '%(%s)T' -1
    local STALE_WORKING_SECS
    STALE_WORKING_SECS=$(_stale_working_secs)

    # ── 1+2. Session + pane data (single tmux call) ────────────
    declare -A sess_state sess_extra sess_seen
    declare -A sess_cwd
    declare -A pane_to_session   # pane_pid → session
    declare -A pane_to_id        # pane_pid → pane_id (e.g. %5)
    declare -A pane_to_window    # pane_id → window_index
    declare -A VISIBLE_PANES=()  # pane_id → 1 when on screen for some client
    declare -A window_names      # session:window_index → window_name
    local all_pane_pids=""

    local _tab=$'\t'
    while IFS=$'\t' read -r sname pane_id pcwd ppid win_idx win_name win_active sess_attached; do
        [ -z "$sname" ] && continue

        # A pane is visible only if its window is the current one in its
        # session and that session has a client attached. Anything else is
        # rendering into a pty nobody is displaying.
        if [ "${win_active:-0}" = "1" ] && [ "${sess_attached:-0}" != "0" ]; then
            VISIBLE_PANES[$pane_id]=1
        fi

        [[ -z "${sess_cwd[$sname]:-}" ]] && sess_cwd[$sname]="$pcwd"
        pane_to_session[$ppid]="$sname"
        pane_to_id[$ppid]="$pane_id"
        pane_to_window[$pane_id]="$win_idx"
        window_names["${sname}:${win_idx}"]="$win_name"
        all_pane_pids+="$ppid "

        [[ -n "${sess_seen[$sname]:-}" ]] && continue
        sess_seen[$sname]=1

        local state="noagent" extra="" status=""

        if [ -f "$STATUS_DIR/${sname}.status" ]; then
            status=$(<"$STATUS_DIR/${sname}.status")
        fi
        [ -n "$status" ] && state="$status"

        rm -f "$STATUS_DIR/${sname}.unread" 2>/dev/null

        sess_state[$sname]="$state"
        sess_extra[$sname]="$extra"
    done < <(tmux list-panes -a -F "#{session_name}${_tab}#{pane_id}${_tab}#{pane_current_path}${_tab}#{pane_pid}${_tab}#{window_index}${_tab}#{window_name}${_tab}#{window_active}${_tab}#{session_attached}" 2>/dev/null)

    # ── 3. Worktree detection ────────────────────────────────────
    declare -A worktree_parent worktree_children

    declare -A root_to_session
    for sname in "${!sess_cwd[@]}"; do
        local cwd="${sess_cwd[$sname]}"
        if [[ "$cwd" != */.claude/worktrees/* ]]; then
            root_to_session[$cwd]="$sname"
        fi
    done

    for sname in "${!sess_cwd[@]}"; do
        local cwd="${sess_cwd[$sname]}"
        if [[ "$cwd" == */.claude/worktrees/* ]]; then
            local repo_root="${cwd%%/.claude/worktrees/*}"
            local parent="${root_to_session[$repo_root]:-}"
            if [ -n "$parent" ] && [ "$parent" != "$sname" ]; then
                worktree_parent[$sname]="$parent"
                worktree_children[$parent]+="$sname "
            fi
        fi
    done

    # ── 4. Multi-agent pane detection ────────────────────────────
    LIVE_PANES=()
    for ppid in $all_pane_pids; do
        local pid="${pane_to_id[$ppid]:-}"
        [ -n "$pid" ] && LIVE_PANES[$pid]=1
    done

    # Rebuild known agents each cycle from current detections plus persisted
    # hook-written pane markers. This avoids stale in-memory agent identities
    # when a pane stops running Claude/Codex but stays open.
    KNOWN_AGENTS=()

    local pane_dir="$STATUS_DIR/panes"
    local agent_file=""
    for agent_file in "$pane_dir/"*.agent; do
        [ -f "$agent_file" ] || continue
        local bname pid_id owner agent_name
        bname=$(basename "$agent_file" .agent)
        pid_id="${bname##*_}"
        owner="${bname%_${pid_id}}"
        [ -n "${LIVE_PANES[$pid_id]:-}" ] || continue
        agent_name=$(<"$agent_file")
        [ -n "$agent_name" ] || continue
        KNOWN_AGENTS["${owner}:${pid_id}"]="$agent_name"
    done

    # Find agent processes — scan ps globally, walk UP to find owning pane.
    # (ps instead of pgrep: macOS pgrep cannot print the command line, which
    # we need to tell claude/codex/devin apart.)
    local agent_lines
    agent_lines=$(scan_agent_processes)
    if [[ -n "$agent_lines" ]]; then
        _build_pid_map
        while read -r agent_name apid acmd; do
            [ -z "$apid" ] && continue

            local pane_pid
            pane_pid=$(find_ancestor_pane "$apid" "$all_pane_pids") || continue
            local owner="${pane_to_session[$pane_pid]:-}"
            [ -z "$owner" ] && continue
            local pid_id="${pane_to_id[$pane_pid]:-}"

            # Hook-written .agent names are authoritative; process detection
            # fills gaps and never downgrades a specific name to "agent".
            local akey="${owner}:${pid_id}"
            local known="${KNOWN_AGENTS[$akey]:-}"
            if [ -z "$known" ] || { [ "$known" = "agent" ] && [ "$agent_name" != "agent" ]; }; then
                KNOWN_AGENTS[$akey]="$agent_name"
            fi
        done <<< "$agent_lines"
    fi

    # Which sessions have per-pane tracking at all? A pane that has not
    # reported is unknown -- not "whatever the busiest pane beside it is doing".
    # Inheriting the session state meant one genuinely working agent lit up
    # every untracked agent pane in the same session, which is the normal case
    # rather than a broken one.
    #
    # Sessions with no per-pane data whatsoever still inherit: that is what the
    # fallback was written for -- a session whose agents have not reported
    # where the session state is the only signal there is.
    declare -A _sess_has_pane_status=()
    local _psf _psb
    for _psf in "$pane_dir"/*.status; do
        [ -f "$_psf" ] || continue
        _psb="${_psf##*/}"
        _psb="${_psb%.status}"
        _sess_has_pane_status["${_psb%_%*}"]=1
    done

    # Build sess_agents from KNOWN_AGENTS + per-pane status files.
    declare -A sess_agents
    # Sample the screens of panes that claim to be working, before resolving
    # states below. Only those panes, and only every few seconds.
    if (( STALE_WORKING_SECS > 0 )); then
        local _working_keys=() _wk _wowner _wpid
        for _wk in "${!KNOWN_AGENTS[@]}"; do
            _wowner="${_wk%%:*}"; _wpid="${_wk#*:}"
            [ -f "$pane_dir/${_wowner}_${_wpid}.status" ] || continue
            [ "$(<"$pane_dir/${_wowner}_${_wpid}.status")" = "working" ] || continue
            _working_keys+=("$_wk")
        done
        (( ${#_working_keys[@]} )) && _sample_working_screens "$now" "$pane_dir" "${_working_keys[@]}"
    fi

    for key in "${!KNOWN_AGENTS[@]}"; do
        local owner="${key%%:*}"
        local pid_id="${key#*:}"
        local agent_name="${KNOWN_AGENTS[$key]}"
        local pane_status=""
        local akey_screen="${owner}:${pid_id}"
        local pane_file="$pane_dir/${owner}_${pid_id}.status"
        if [ -f "$pane_file" ]; then
            pane_status=$(<"$pane_file")
        fi
        # A "working" status the pane's own screen contradicts.
        #
        # State is pushed by hooks and nothing expires it, so a Stop that never
        # fires -- an agent killed, interrupted, or whose hook path broke --
        # leaves "working" set forever. Observed at 903 minutes, with the agent
        # process alive and idle, so process liveness does not catch it.
        #
        # An agent that is working repaints its pane: a spinner, a token
        # counter, a tool result scrolling past. One that has finished holds a
        # static prompt. So a screen that has not changed for many minutes
        # contradicts the status.
        #
        # Resolve to "idle", never "done": the honest claim is "no longer
        # believable", not "finished", and "done" would show a tick and fire the
        # completion sound for work that may never have completed.
        if [ "$pane_status" = "working" ] && (( STALE_WORKING_SECS > 0 )); then
            local _chg="${_SCREEN_TS[$akey_screen]:-}"
            if [ -n "$_chg" ] && (( now - _chg > STALE_WORKING_SECS )); then
                pane_status="idle"
            fi
        fi

        if [ -z "$pane_status" ]; then
            if [ -n "${_sess_has_pane_status[$owner]:-}" ]; then
                # Tracked session, silent pane: unknown. Renders as a dim dot,
                # and _state_pri gives it 0 so it cannot raise session state.
                pane_status="idle"
            else
                pane_status="${sess_state[$owner]:-done}"
            fi
        fi
        sess_agents[$owner]+="${pid_id}:${agent_name}:${pane_status} "
    done

    # ── 5. Re-derive session state from per-pane statuses ──────
    for sname in "${!sess_agents[@]}"; do
        local cur_st="${sess_state[$sname]}"
        local best_pri=-1 best_st="$cur_st"
        best_pri=$(_state_pri "$best_st" 2>/dev/null || echo 0)
        for ap in ${sess_agents[$sname]}; do
            local rest="${ap#*:}"; rest="${rest#*:}"
            local ps="${rest%%:*}"
            local pp
            pp=$(_state_pri "$ps" 2>/dev/null || echo 0)
            if (( pp > best_pri )); then
                best_pri=$pp; best_st="$ps"
            fi
        done
        sess_state[$sname]="$best_st"
    done

    # ── 5a. Shared status-line summary counts ────────────────────
    for sname in "${!sess_state[@]}"; do
        case "${sess_state[$sname]}" in
            working)
                ((SUMMARY_WORKING++))
                ((SUMMARY_TOTAL++))
                SUMMARY_HAS_WORKING=1
                ;;
            done|ask)
                ((SUMMARY_DONE++))
                ((SUMMARY_TOTAL++))
                ;;
            *)
                ;;
        esac
    done

    # ── 5a'. Per-agent status-line list ─────────────────────────
    # One "name:status" spec per agent, ordered by session name then pane
    # id so glyph positions in the status bar stay stable across refreshes.
    # Sessions with detected agent panes contribute one spec per pane;
    # sessions tracked only at session level contribute
    # a single generic spec.
    SUMMARY_AGENTS=()
    while IFS= read -r sname; do
        [ -z "$sname" ] && continue
        local sstate="${sess_state[$sname]}"
        case "$sstate" in
            working|done|ask) ;;
            *) continue ;;
        esac

        if [ -z "${sess_agents[$sname]:-}" ]; then
            SUMMARY_AGENTS+=("agent:${sstate}")
            continue
        fi

        local ap
        while IFS= read -r ap; do
            [ -z "$ap" ] && continue
            local aname="${ap#*:}"
            aname="${aname%%:*}"
            local astatus="${ap#*:}"
            astatus="${astatus#*:}"
            case "$astatus" in
                working|done|ask)
                    SUMMARY_AGENTS+=("${aname}:${astatus}")
                    ;;
            esac
        done < <(printf '%s\n' ${sess_agents[$sname]} | sort)
    done < <(printf '%s\n' "${!sess_state[@]}" | sort)

    # ── 5b. Compute per-session pane counts ─────────────────────
    PANE_COUNTS=()
    for sname in "${!sess_agents[@]}"; do
        local agents="${sess_agents[$sname]}"
        local pw=0 pd=0 count=0
        local seen=""
        for ap in $agents; do
            local pid="${ap%%:*}"
            [[ " $seen " == *" $pid "* ]] && continue
            seen+="$pid "
            local rest="${ap#*:}"; local ps="${rest#*:}"
            case "$ps" in
                working) ((pw++)) ;; done|ask) ((pd++)) ;;
            esac
            ((count++))
        done
        (( count > 1 )) && PANE_COUNTS[$sname]="${pw}:${pd}"
    done

    # ── 6. Collapse single-worktree parents ────────────────────
    for parent in "${!worktree_children[@]}"; do
        local children=(${worktree_children[$parent]})
        if (( ${#children[@]} < 2 )); then
            for child in "${children[@]}"; do
                unset "worktree_parent[$child]"
            done
            unset "worktree_children[$parent]"
        fi
    done

    # ── 7. Compute effective state (bubble-up) ─────────────────
    declare -A eff_state
    for sname in "${!sess_state[@]}"; do
        eff_state[$sname]="${sess_state[$sname]}"
    done
    for parent in "${!worktree_children[@]}"; do
        local best="${eff_state[$parent]}"
        local best_pri
        best_pri=$(_state_pri "$best")
        for child in ${worktree_children[$parent]}; do
            local cp
            cp=$(_state_pri "${sess_state[$child]}")
            if (( cp > best_pri )); then
                best_pri=$cp
                best="${sess_state[$child]}"
            fi
        done
        eff_state[$parent]="$best"
    done

    local all_sessions=()
    for sname in "${!sess_state[@]}"; do
        all_sessions+=("$sname")
    done
    if (( ${#all_sessions[@]} > 0 )); then
        IFS=$'\n' all_sessions=($(sort <<< "${all_sessions[*]}")); unset IFS
    fi

    # ── 8. Build ENTRIES ─────────────────────────────────────────

    _get_agent_arr() {
        local session="$1"
        local agents="${sess_agents[$session]:-}"
        _agent_result=()
        [ -z "$agents" ] && return
        local seen=""
        for ap in $agents; do
            local pid="${ap%%:*}"
            [[ " $seen " == *" $pid "* ]] && continue
            seen+="$pid "
            _agent_result+=("$ap")
        done
    }

    _emit_agents() {
        local sname="$1"
        _get_agent_arr "$sname"
        local agents=("${_agent_result[@]}")
        # Tree mode collapses single-agent sessions to just the session row.
        # Agents mode expands every agent pane, even when there is only one.
        if [[ "$SIDEBAR_MODE" != "agents" ]]; then
            (( ${#agents[@]} <= 1 )) && return
        else
            (( ${#agents[@]} == 0 )) && return
        fi

        local -A win_agents=() win_seen=()
        local -a win_order=()
        for ap in "${agents[@]}"; do
            local pid="${ap%%:*}"
            local wi="${pane_to_window[$pid]:-0}"
            [[ -z "${win_seen[$wi]:-}" ]] && { win_order+=("$wi"); win_seen[$wi]=1; }
            win_agents[$wi]+="$ap "
        done

        # Windows are discovered above by walking agent panes, so a window with
        # no agent in it is never seen. window_names already holds every window
        # (it is filled from `list-panes -a`), so opt in by folding the rest of
        # the session's windows in, then ordering the whole set by index.
        if [[ "${SHOW_ALL_WINDOWS:-0}" == "1" ]]; then
            local wkey wid
            for wkey in "${!window_names[@]}"; do
                [[ "$wkey" == "${sname}:"* ]] || continue
                wid="${wkey##*:}"
                [[ -z "${win_seen[$wid]:-}" ]] && { win_order+=("$wid"); win_seen[$wid]=1; }
            done
            if (( ${#win_order[@]} > 1 )); then
                local -a _ordered=()
                while IFS= read -r wid; do
                    [ -n "$wid" ] && _ordered+=("$wid")
                done < <(printf '%s\n' "${win_order[@]}" | sort -n)
                win_order=("${_ordered[@]}")
            fi
        fi

        if (( ${#win_order[@]} == 1 )); then
            local ai=0 total=${#agents[@]}
            for ap in "${agents[@]}"; do
                ((ai++))
                local pid="${ap%%:*}" r="${ap#*:}"
                local agent="${r%%:*}" st="${r#*:}"
                ENTRIES+=("P|${sname}|${pid}|${agent}|${st}|$((ai==total))")
                SEL_NAMES+=("${sname}:${pid}")
                SEL_TYPES+=("P")
            done
        else
            local nw=${#win_order[@]} wi=0
            for widx in "${win_order[@]}"; do
                ((wi++))
                local wname="${window_names[${sname}:${widx}]:-window-$widx}"
                local w_last=$((wi==nw))
                local pc=0
                for _ in ${win_agents[$widx]}; do ((pc++)); done

                if (( pc == 0 )); then
                    # Only reachable with @agent-show-all-windows on. "noagent"
                    # scores 0 in _state_pri, below every real agent state.
                    ENTRIES+=("P|${sname}|w${widx}|${wname}|noagent|${w_last}")
                    SEL_NAMES+=("${sname}:w${widx}")
                    SEL_TYPES+=("P")
                else
                    # Every window holding an agent expands, including one
                    # holding a single agent. Collapsing the single-agent case
                    # into the window row hid the agent behind the window's
                    # name, so the same pane appeared as "claude" beside a
                    # sibling and as the window name when alone -- and left a
                    # single-agent window indistinguishable from an agent-less
                    # one apart from its status glyph.
                    local best_pri=-1 best_st="noagent"
                    for wap in ${win_agents[$widx]}; do
                        local ws="${wap#*:}"; ws="${ws#*:}"
                        local wp; wp=$(_state_pri "$ws" 2>/dev/null || echo 0)
                        (( wp > best_pri )) && { best_pri=$wp; best_st="$ws"; }
                    done
                    ENTRIES+=("P|${sname}|w${widx}|${wname}|${best_st}|${w_last}")
                    SEL_NAMES+=("${sname}:w${widx}")
                    SEL_TYPES+=("P")
                    local ai=0
                    for wap in ${win_agents[$widx]}; do
                        ((ai++))
                        local pid="${wap%%:*}" r="${wap#*:}"
                        local agent="${r%%:*}" st="${r#*:}"
                        ENTRIES+=("Q|${sname}|${pid}|${agent}|${st}|$((ai==pc))|${w_last}")
                        SEL_NAMES+=("${sname}:${pid}")
                        SEL_TYPES+=("P")
                    done
                fi
            done
        fi
    }

    _emit_session() {
        local entry="$1" sname="$2"
        ENTRIES+=("$entry")
        SEL_NAMES+=("$sname")
        SEL_TYPES+=("S")

        local wt_list="${worktree_children[$sname]:-}"
        local wt_names=()
        for wt in $wt_list; do
            # In agents mode, hide worktree children that have no agents.
            if [[ "$SIDEBAR_MODE" == "agents" ]] && [[ -z "${sess_agents[$wt]:-}" ]]; then
                continue
            fi
            wt_names+=("$wt")
        done
        local wi=0
        for wt in "${wt_names[@]}"; do
            ((wi++))
            local is_last=$((wi==${#wt_names[@]}))
            ENTRIES+=("W|${wt}|${sess_state[$wt]}|${sess_extra[$wt]}|${is_last}")
            SEL_NAMES+=("$wt")
            SEL_TYPES+=("W")
            _emit_agents "$wt"
        done

        _emit_agents "$sname"
    }

    # ── INBOX ────────────────────────────────────────────────────
    if [[ "$SIDEBAR_MODE" != "agents" ]] && (( $(_inbox_enabled) )); then
        local inbox=()
        for sname in "${all_sessions[@]}"; do
                if [[ -n "${sess_agents[$sname]:-}" ]]; then
                _get_agent_arr "$sname"
                local arr=("${_agent_result[@]}")
                if (( ${#arr[@]} <= 1 )); then
                    local ap="${arr[0]:-}"
                    local pst="${ap#*:}"; pst="${pst#*:}"
                    [[ "$pst" == "done" || "$pst" == "ask" ]] && inbox+=("I|${sname}||${sname}|done")
                    continue
                fi

                local -A _ib_win=()
                for ap in "${arr[@]}"; do
                    local pid="${ap%%:*}"
                    local wi="${pane_to_window[$pid]:-0}"
                    _ib_win[$wi]+="$ap "
                done

                if (( ${#_ib_win[@]} == 1 )); then
                    local only_wi=""
                    for only_wi in "${!_ib_win[@]}"; do
                        break
                    done

                    local ai=0
                    local pid=""
                    while IFS= read -r pid; do
                        [ -n "$pid" ] || continue

                        local ap=""
                        local candidate=""
                        for candidate in ${_ib_win[$only_wi]}; do
                            [ "${candidate%%:*}" = "$pid" ] || continue
                            ap="$candidate"
                            break
                        done
                        [ -n "$ap" ] || continue

                        ((ai++))
                        local r="${ap#*:}"
                        local aname="${r%%:*}"
                        local pst="${r#*:}"
                        [[ "$pst" == "done" || "$pst" == "ask" ]] && inbox+=("I|${sname}|${pid}|${sname} › ${aname} #${ai}|done")
                    done < <(tmux list-panes -t "${sname}:${only_wi}" -F "#{pane_id}" 2>/dev/null)
                else
                    local wi=""
                    while IFS= read -r wi; do
                        [ -n "${_ib_win[$wi]:-}" ] || continue

                        local wname="${window_names[${sname}:${wi}]:-window-$wi}"
                        local any_done=0
                        local wap=""
                        for wap in ${_ib_win[$wi]}; do
                            local ws="${wap#*:}"
                            ws="${ws#*:}"
                            [[ "$ws" == "done" || "$ws" == "ask" ]] && any_done=1
                        done
                        (( any_done )) && inbox+=("I|${sname}|w${wi}|${sname} › ${wname}|done")
                    done < <(tmux list-windows -t "$sname" -F "#{window_index}" 2>/dev/null)
                fi

                continue
            fi

            [[ -n "${worktree_parent[$sname]:-}" ]] && continue
            local st="${eff_state[$sname]}"
            [[ "$st" == "done" || "$st" == "ask" ]] && inbox+=("I|${sname}||${sname}|done")
        done

        if (( ${#inbox[@]} > 0 )); then
            ENTRIES+=("G|INBOX|green")
            for entry in "${inbox[@]}"; do
                ENTRIES+=("$entry")
                local r="${entry#I|}"
                local sname="${r%%|*}"; r="${r#*|}"
                local token="${r%%|*}"
                if [[ -n "$token" ]]; then
                    SEL_NAMES+=("${sname}:${token}")
                    SEL_TYPES+=("P")
                else
                    SEL_NAMES+=("$sname")
                    SEL_TYPES+=("S")
                fi
            done
        fi
    fi

    # ── SESSIONS ─────────────────────────────────────────────────
    local sorted_sessions=()
    for sname in "${all_sessions[@]}"; do
        [[ -n "${worktree_parent[$sname]:-}" ]] && continue
        # In agents mode, only list sessions that have at least one
        # agent pane (after collapsing single-worktree-parents above,
        # a parent inherits its worktree children through eff_state but
        # not through sess_agents — so also keep it if any of its
        # worktree children carry agents).
        if [[ "$SIDEBAR_MODE" == "agents" ]]; then
            local _has_agents=0
            [[ -n "${sess_agents[$sname]:-}" ]] && _has_agents=1
            if (( ! _has_agents )); then
                for _wt in ${worktree_children[$sname]:-}; do
                    [[ -n "${sess_agents[$_wt]:-}" ]] && { _has_agents=1; break; }
                done
            fi
            (( _has_agents )) || continue
        fi
        sorted_sessions+=("$sname")
    done

    SESS_START=${#SEL_NAMES[@]}
    if (( ${#sorted_sessions[@]} > 0 )); then
        ENTRIES+=("G|SESSIONS|gray")
        for sname in "${sorted_sessions[@]}"; do
            local st="${eff_state[$sname]}"
            local ex="${sess_extra[$sname]}"
            local entry="S|${sname}|${st}|${ex}"
            _emit_session "$entry" "$sname"
        done
    fi

    # ── 9. Clean up dead sessions ────────────────────────────────
    for sf in "$STATUS_DIR"/*.status; do
        [ -f "$sf" ] || continue
        local sname
        sname=$(basename "$sf" .status)
        [[ -n "${sess_seen[$sname]:-}" ]] && continue
        rm -f "$sf"
        rm -f "$STATUS_DIR/panes/${sname}_"*.status "$STATUS_DIR/panes/${sname}_"*.agent
    done

    # Clean up pane metadata for dead panes.
    for psf in "$STATUS_DIR/panes/"*.status; do
        [ -f "$psf" ] || continue
        local bname pid_id
        bname=$(basename "$psf" .status)
        pid_id="${bname##*_}"
        [[ -z "${LIVE_PANES[$pid_id]:-}" ]] && rm -f "$psf"
    done
    for paf in "$STATUS_DIR/panes/"*.agent; do
        [ -f "$paf" ] || continue
        local bname pid_id
        bname=$(basename "$paf" .agent)
        pid_id="${bname##*_}"
        [[ -z "${LIVE_PANES[$pid_id]:-}" ]] && rm -f "$paf"
    done

    # Publish which sidebar panes are on screen. Renderers read this instead of
    # asking tmux, so deciding whether to animate costs a file read rather than
    # an IPC round trip per renderer.
    {
        local vp
        for vp in "${!VISIBLE_PANES[@]}"; do printf '%s\n' "$vp"; done
    } > "$VISIBLE_FILE.tmp.$$" 2>/dev/null && mv -f "$VISIBLE_FILE.tmp.$$" "$VISIBLE_FILE" 2>/dev/null
}
