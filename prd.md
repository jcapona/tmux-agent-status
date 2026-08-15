# PRD: Architecture Overhaul — Event-Driven Collection, O(1) Rendering, and Socket IPC

## Problem

**Who:** Users running tmux-agent-status with many tmux windows (20+).

**What pain:** The plugin causes excessive CPU usage, heat, and battery drain. With 30 windows and the default `@agent-sidebar-per-window "on"`, the system runs 33 long-lived bash processes and generates ~120 process wakeups per second and ~11 `tmux list-panes -a` IPC calls per second — all steady-state, even when no agent state has changed. The cost scales linearly with window count (O(windows × ticks)) when it should be O(1).

**Why now:** The performance problem is architectural, not a tuning issue. Three root causes compound:

1. **N sidebar processes rendering identical content.** Each window gets its own `sidebar.sh` process. The sidebar tree is the same in every window, so 30 processes read the same cache file and render the same tree 30 times.
2. **Broadcast animation at 4 fps.** The collector sends USR2 to every sidebar client every 0.25s for spinner animation. Each `signal_sidebar_clients` call does a `tmux list-panes -a` IPC call, then signals N processes. That is 4 × (1 IPC call + N signal deliveries) per second, purely for cosmetic spinners.
3. **Polling collector with full process-table scans.** The collector polls at 0.25s, and every second it runs `ps -eo pid=,ppid=,args=` (full process table dump) + `tmux list-panes -a` + BFS traversal, even when nothing changed. Hooks already know what changed but discard that information by writing to files.

## Objective & Scope

**Single measurable goal:** Reduce steady-state CPU cost from O(windows × ticks) to O(1) in window count, with zero regression in sidebar latency, interactivity, or custom-agent file compatibility.

**In scope:**
- Eliminate the animation broadcast (USRS2) path
- Cache pane enumeration so the signal path does zero `tmux` IPC
- Consolidate sidebar rendering to one process per session with shared output
- Replace the 0.25s polling collector with kqueue/inotify event-driven collection
- Collapse the three-layer daemon stack (collector + smart-monitor + daemon-monitor) into one process
- Add a Unix domain socket as the fast IPC path; keep file-based status files as the compatibility path for custom agents
- Push rendered state to subscribers from in-memory model instead of serializing a cache file

**Not in scope:**
- Rewriting the sidebar renderer in a compiled language (Go/Rust). The sidebar remains bash. This is a future optimization that becomes easier after the architecture changes but is not required to achieve O(1).
- Changing the hook scripts (`better-hook.sh`, `codex-hook.sh`, `devin-hook.sh`). They remain thin shell scripts writing to the same status files. The socket is an additional fast path, not a replacement.
- Changing the fzf switcher (`hook-based-switcher.sh`). It is on-demand, not always-running, and not a performance problem.
- Changing the status-line module. It reads from the summary cache, which the daemon continues to write. The animation frames are already local (status-interval drives the frame, not a signal).
- Changing the tmux keybindings or user-facing options. All existing `@agent-*` options continue to work.

## Requirements

### Phase 1: Stop the bleeding (tactical, no contract changes)

| ID | Priority | Requirement | Verification |
|----|----------|-------------|--------------|
| 1.1 | P0 | The collector must not send USR2 (animation signal) to sidebar clients. Spinner animation is each sidebar's own local timer, driven by its `read -t` timeout loop. | `grep -r 'USR2' scripts/sidebar-collector.sh` returns no `signal_sidebar_clients USR2` call. `grep -r 'handle_animation_signal\|USR2' scripts/sidebar.sh` shows the trap handler still exists (backward compat) but is never the animation driver. |
| 1.2 | P0 | Each sidebar process animates its own spinner locally. When `_HAS_WORKING` is set, the sidebar's main loop advances `SPINNER_TICK` and calls `animate_spinners` on its own `read -t 0.25` timeout, without being woken by an external signal. | `tests/sidebar-local-animation.sh`: spawn a sidebar with `_HAS_WORKING=1` and no USR2 signal sent; assert spinner frames advance over 2 seconds. |
| 1.3 | P0 | `signal_sidebar_clients` must not call `tmux list-panes -a` on every invocation. Pane-title validation is cached and refreshed at most once every 5 seconds. The signal path is `kill -s` over PID files only. | `grep 'list-panes -a' scripts/lib/sidebar-clients.sh` shows the call is inside a throttled refresh function, not in the signal delivery loop. `tests/sidebar-signal-no-ipc.sh`: call `signal_sidebar_clients` 10 times in 1 second with a fake `tmux` that logs calls; assert `tmux` was invoked at most once. |
| 1.4 | P0 | Existing USR1 (data-changed) signal behavior is preserved. When the collector detects a real state change, it signals all sidebar clients to re-collect and re-render. | `tests/sidebar-client-signals.sh` continues to pass (USR1 all-scope test). The USR2 active-scope assertions are removed or inverted (USR2 is no longer sent by the collector). |

### Phase 2: Renderer consolidation

| ID | Priority | Requirement | Verification |
|----|----------|-------------|--------------|
| 2.1 | P0 | When `@agent-sidebar-per-window "on"`, only one sidebar renderer process runs per session. Additional windows in the same session display the renderer's output via a lightweight display proxy (reads a rendered output file, no event loop, no `tmux` IPC). | `tests/sidebar-single-renderer.sh`: create a session with 5 windows, `@agent-sidebar-per-window on`; assert exactly 1 `sidebar.sh` process and N-1 display proxy processes. `pgrep -fc sidebar.sh` returns 1 per session. |
| 2.2 | P0 | The renderer writes rendered output (ANSI escape sequences) to `$STATUS_DIR/.sidebar-render.<session>` on every render. Display proxies `tail -f` or poll this file at 1s and write to their pane. | `tests/sidebar-shared-output.sh`: renderer writes 3 lines to the output file; assert all display proxies in the session show the same content within 2s. |
| 2.3 | P1 | Interactive input (mouse clicks, `x`/`p`/`w` keys, mode toggle `m`) in any sidebar pane forwards to the single renderer process. The renderer processes the action and re-renders. | `tests/sidebar-input-forwarding.sh`: send a `p` (park) key to a display proxy pane; assert the park action is applied and the rendered output file updates within 1s. |
| 2.4 | P1 | `@agent-sidebar-per-window "off"` (one per session) behavior is unchanged. The renderer process IS the sidebar pane; no proxy is spawned. | `tests/sidebar-per-session.sh`: `@agent-sidebar-per-window off`; assert 1 `sidebar.sh` process, 0 proxies. |
| 2.5 | P0 | Closing a window with a display proxy kills the proxy. Closing the window with the renderer migrates the renderer to another window in the same session (or kills it if no windows remain). | `tests/sidebar-renderer-migration.sh`: kill the renderer's window; assert a new renderer spawns in another window of the same session within 2s. |

### Phase 3: Event-driven collection

| ID | Priority | Requirement | Verification |
|----|----------|-------------|--------------|
| 3.1 | P0 | The collector uses filesystem event notification (`kqueue` on macOS via `bash`+`stat` polling fallback, `inotifywait`/`inotify` on Linux) to detect status file changes, instead of a fixed 0.25s poll loop. When no files change, the collector does zero work. | `tests/collector-event-driven.sh`: write a status file; assert the collector processes the change within 100ms. Delete the file; assert no `ps` or `tmux list-panes` call occurs for 5s of idle. |
| 3.2 | P0 | When `inotifywait` (Linux) or a kqueue-based watcher is unavailable, the collector falls back to the current mtime-based polling at 1s intervals (not 0.25s). The fallback is logged once to stderr. | `tests/collector-fallback-poll.sh`: set `PATH` to exclude `inotifywait`; assert collector falls back to polling and logs the fallback. Assert poll interval is 1s, not 0.25s. |
| 3.3 | P0 | The collector still runs a full `collect_data` (with `ps` + `tmux list-panes -a`) at most once per state change, and a periodic liveness sweep at most once every 30s (not every second). The liveness sweep reconciles pane/process changes that don't touch status files (e.g. an agent process exiting without a Stop hook). | `tests/collector-liveness-interval.sh`: run collector for 35s with no status file changes; assert `ps` is invoked at most twice (once at start, once at 30s). |
| 3.4 | P1 | Latency from hook writing a status file to sidebar re-render is under 200ms (down from 250ms-1s today). | `tests/collector-latency.sh`: write a status file; measure time until `signal_sidebar_clients USR1` fires; assert < 200ms. |

### Phase 4: Daemon consolidation

| ID | Priority | Requirement | Verification |
|----|----------|-------------|--------------|
| 4.1 | P0 | The three-process daemon stack (sidebar-collector.sh + smart-monitor.sh + daemon-monitor.sh) is replaced by a single `agent-daemon.sh` process. It is self-supervising: a tmux `session-created` hook starts it if not running, and it self-exits when tmux has no sessions. | `pgrep -fc 'agent-daemon.sh'` returns at most 1. `pgrep -fc 'smart-monitor.sh'` returns 0. `pgrep -fc 'daemon-monitor.sh'` returns 0. `tests/daemon-single-process.sh`: kill the daemon; assert a tmux session-created hook restarts it within 5s. |
| 4.2 | P0 | The daemon holds all agent state in memory (associative arrays). It no longer serializes a `.sidebar-cache` file. Sidebar processes and display proxies receive rendered output directly from the daemon via the subscriber protocol (Phase 5) or by reading a rendered output file that the daemon writes. | `ls ~/.cache/tmux-agent-status/.sidebar-cache` returns no such file after the daemon has been running. `tests/daemon-no-cache-file.sh`: start daemon, trigger a state change; assert `.sidebar-cache` is never created. |
| 4.3 | P0 | The daemon writes the status-line summary cache (`.status-line` + `.status-line-counts`) as before, since the status-line module reads it via `status-interval` and is not a subscriber. | `tests/status-line-cache.sh` continues to pass. |

### Phase 5: Socket IPC

| ID | Priority | Requirement | Verification |
|----|----------|-------------|--------------|
| 5.1 | P0 | The daemon listens on a Unix domain socket at `$STATUS_DIR/agent-daemon.sock`. Hooks may write one-line events to the socket as a fast path: `<agent> <session> <pane> <state>` (e.g. `claude mysession %3 working`). The daemon updates its in-memory model and signals subscribers in the same event-loop turn. | `tests/socket-fast-path.sh`: write `claude testsession %1 working` to the socket; assert the daemon processes it and subscribers receive USR1 within 100ms. |
| 5.2 | P0 | Hooks that do not use the socket continue to write status files. The daemon watches these files via the event-notification mechanism from Phase 3 and processes them the same way. The file path is the compatibility path; the socket is the fast path. | `tests/file-compat-path.sh`: write `working` to `$STATUS_DIR/testsession.status` (no socket write); assert the daemon processes it and subscribers receive USR1 within 200ms. |
| 5.3 | P0 | Sidebar processes and display proxies connect to the socket as subscribers. On state change, the daemon pushes a rendered output frame to each subscriber's socket connection. The subscriber writes it to its pane (or to the shared output file for proxies). | `tests/socket-subscriber.sh`: connect a subscriber to the socket; trigger a state change; assert the subscriber receives a rendered frame within 100ms. |
| 5.4 | P1 | If the socket is unavailable (daemon not started, socket deleted), sidebar processes fall back to reading status files directly and rendering locally (the current behavior). The plugin degrades gracefully. | `tests/socket-fallback.sh`: remove the socket; start a sidebar; assert it renders from status files directly and does not crash. |
| 5.5 | P0 | The socket protocol is line-based and human-readable for debuggability. Events in: `<agent> <session> <pane> <state>`. Subscriptions in: `SUB <pane_id>`. State snapshots out: `FRAME <len>\n<rendered output>`. | `echo 'SUB %5' | nc -U ~/.cache/tmux-agent-status/agent-daemon.sock` returns a `FRAME` message. `tests/socket-protocol.sh`: assert protocol format. |

## Interface Contracts

### Hook → Daemon (fast path, socket)

```
Input:  one line on Unix socket: "<agent> <session> <pane> <state>"
        agent:  claude | codex | devin | custom
        session: tmux session name (no spaces)
        pane:    tmux pane_id (%N) or empty for session-level
        state:   working | done | wait | ask
Output: none (fire-and-forget); daemon processes asynchronously
Errors: if socket unavailable, hook silently falls back to writing status file
        (existing behavior, no change to hook scripts in this PRD)
```

### Hook → File (compatibility path, unchanged)

```
Input:  hook writes to:
        $STATUS_DIR/<session>.status           (session-level state)
        $STATUS_DIR/panes/<session>_<pane>.status  (pane-level state)
        $STATUS_DIR/wait/<session>[_<pane>].wait   (wait timer, epoch seconds)
        $STATUS_DIR/parked/<session>[_<pane>].parked  (park marker)
Output: file content is a single line: "working" | "done" | "wait" | "ask"
Errors: none; file writes are best-effort, daemon reconciles
Note:   this contract is UNCHANGED. Custom agents that write files
        continue to work without modification.
```

### Daemon → Subscriber (socket, push)

```
Input:  subscriber connects to $STATUS_DIR/agent-daemon.sock
        and sends: "SUB <pane_id>\n"
Output: daemon pushes rendered frames:
        "FRAME <byte_len>\n<raw ANSI output>\n"
        on every state change affecting the subscriber's session
Errors: if subscriber disconnects, daemon removes it from the subscriber
        list on next write attempt (EPIPE)
```

### Daemon → Display Proxy (file, Phase 2)

```
Input:  daemon writes rendered ANSI output to:
        $STATUS_DIR/.sidebar-render.<session>
Output: display proxy reads this file (tail -f or 1s poll) and
        writes raw bytes to its tmux pane
Errors: if file is missing, proxy shows a blank sidebar and retries
```

### Daemon → Status Line (file, unchanged)

```
Input:  daemon writes:
        $STATUS_DIR/.status-line         (two lines, one per animation frame)
        $STATUS_DIR/.status-line-counts  (working:waiting:done:total)
Output: status-line.sh reads these files on each status-interval tick
Errors: if files are missing, status-line.sh outputs empty string
Note:   this contract is UNCHANGED.
```

### Sidebar → User (terminal, unchanged)

```
Input:  keyboard (arrows, Enter, x, p, w, m, /) and mouse (SGR clicks)
Output: ANSI-rendered tree or agents view in the sidebar pane
Errors: if pane is destroyed, sidebar process exits (existing liveness check)
Note:   this contract is UNCHANGED. Only the process topology behind it
        changes (one renderer + N proxies instead of N renderers).
```

## Test Expectations

| Requirement | Test file | What it asserts |
|------------|----------|-----------------|
| 1.1 | `tests/no-broadcast-animation.sh` | Collector sends zero USR2 signals over 5s with an agent working |
| 1.2 | `tests/sidebar-local-animation.sh` | Sidebar advances spinner frames on its own timer with no USR2 |
| 1.3 | `tests/sidebar-signal-no-ipc.sh` | `signal_sidebar_clients` calls `tmux` at most once per 5s, not per-call |
| 1.4 | `tests/sidebar-client-signals.sh` | USR1 all-scope still works; USR2 assertions removed |
| 2.1 | `tests/sidebar-single-renderer.sh` | One renderer + N-1 proxies per session |
| 2.2 | `tests/sidebar-shared-output.sh` | All proxies show same rendered content within 2s |
| 2.3 | `tests/sidebar-input-forwarding.sh` | Key input in proxy reaches renderer, action applied |
| 2.4 | `tests/sidebar-per-session.sh` | Per-session mode: 1 renderer, 0 proxies |
| 2.5 | `tests/sidebar-renderer-migration.sh` | Renderer migrates when its window is killed |
| 3.1 | `tests/collector-event-driven.sh` | Change detected < 100ms; idle does zero work for 5s |
| 3.2 | `tests/collector-fallback-poll.sh` | Falls back to 1s polling when inotify/kqueue unavailable |
| 3.3 | `tests/collector-liveness-interval.sh` | `ps` called at most twice in 35s of idle |
| 3.4 | `tests/collector-latency.sh` | Hook → signal latency < 200ms |
| 4.1 | `tests/daemon-single-process.sh` | One daemon process; restarts on death |
| 4.2 | `tests/daemon-no-cache-file.sh` | `.sidebar-cache` never created |
| 4.3 | `tests/status-line-cache.sh` | Status-line cache still written and read (existing test) |
| 5.1 | `tests/socket-fast-path.sh` | Socket event processed, subscriber signaled < 100ms |
| 5.2 | `tests/file-compat-path.sh` | File write processed, subscriber signaled < 200ms |
| 5.3 | `tests/socket-subscriber.sh` | Subscriber receives FRAME on state change |
| 5.4 | `tests/socket-fallback.sh` | Sidebar renders from files when socket unavailable |
| 5.5 | `tests/socket-protocol.sh` | Protocol format is line-based, human-readable |

## Implementation Order

The phases are designed to be independently shippable. Each phase delivers value on its own and does not depend on later phases:

1. **Phase 1** (1-2 days): Kill animation broadcast + cache pane enumeration. Biggest CPU win, smallest diff. No new processes, no protocol changes, no new files. Existing tests need minor updates (USR2 assertions removed).

2. **Phase 2** (3-5 days): Renderer consolidation. Eliminates 29 redundant processes at 30 windows. Requires a display proxy script and a rendered-output file. The renderer process model changes but the user-facing behavior does not.

3. **Phase 3** (2-3 days): Event-driven collection. Requires `inotifywait` (Linux) or a kqueue wrapper (macOS). Falls back to slower polling. Eliminates the 4×/sec `ps` + `tmux list-panes -a` cost.

4. **Phase 4** (1-2 days): Daemon consolidation. Merges three scripts into one. Mostly deletion + renaming. The daemon's in-memory model already exists in `collect.sh`; this just stops serializing it.

5. **Phase 5** (3-5 days): Socket IPC. Adds the fast path and subscriber push. The file path remains for compatibility. This is the most structurally new work but builds on all prior phases.

**Total estimate: 10-17 days**, with Phase 1 shippable in the first PR.

## Migration & Compatibility

- **Custom agents**: No change required. File-based status writes continue to work. The daemon watches files via Phase 3's event notification.
- **Hook scripts**: No change required in this PRD. The socket fast path (Phase 5) is opt-in: hooks can be updated to also write to the socket, but the file path remains the default. A future PRD can migrate hooks to socket-only.
- **User options**: All `@agent-*` options continue to work. No option is removed or renamed. `@agent-sidebar-per-window` still controls sidebar placement; the difference is process topology behind it.
- **Status line**: Unchanged. The daemon continues to write `.status-line` and `.status-line-counts`.
- **Remote/SSH sessions**: Unchanged. Remote sessions write to `-remote.status` files; the daemon watches them the same way.

## Completion Checklist

- [x] Problem section drafted
- [x] Objective & Scope section drafted
- [x] Requirements table drafted (P0/P1/P2 with verification)
- [x] Interface Contracts section drafted
- [x] Test Expectations table drafted
- [x] Implementation Order section drafted
- [x] Migration & Compatibility section drafted
