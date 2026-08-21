#!/usr/bin/env bash
#
# CPU benchmark for the collector and sidebar renderers.
#
# Measuring on a live tmux server does not work: the number of working agents
# changes minute to minute and it drives almost all of the cost, so two runs of
# the same code can differ by more than the change being evaluated. Every
# comparison made that way is unfalsifiable.
#
# This builds a fixed world instead — its own tmux server on a private socket,
# a set number of sessions and windows, and a set number of agents pinned in
# "working" via the documented status-file integration, so no real agent has to
# be running. Then it samples actual CPU time (not ps %cpu, which is a lifetime
# average) over several trials and reports the spread.
#
#   tools/bench.sh                                  defaults
#   tools/bench.sh --sessions 4 --windows 5 --agents 12 --trials 3
#   tools/bench.sh --label "before"                 tag the output
#
# To compare two variants, run it on each and compare means. Anything smaller
# than the reported spread is noise.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SESSIONS=4
WINDOWS=5
AGENTS=12
TRIALS=3
SETTLE=20
SAMPLE=30
LABEL=""

while [ $# -gt 0 ]; do
    case "$1" in
        --sessions) SESSIONS="$2"; shift 2 ;;
        --windows)  WINDOWS="$2";  shift 2 ;;
        --agents)   AGENTS="$2";   shift 2 ;;
        --trials)   TRIALS="$2";   shift 2 ;;
        --settle)   SETTLE="$2";   shift 2 ;;
        --sample)   SAMPLE="$2";   shift 2 ;;
        --label)    LABEL="$2";    shift 2 ;;
        -h|--help)  sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

REAL_TMUX="$(command -v tmux)"
[ -n "$REAL_TMUX" ] || { echo "tmux not found" >&2; exit 1; }

SOCKET="agentbench$$"
TMP_DIR="$(mktemp -d)"
export HOME="$TMP_DIR/home"
STATUS_DIR="$HOME/.cache/tmux-agent-status"
mkdir -p "$STATUS_DIR/panes" "$TMP_DIR/bin"

# The plugin calls bare `tmux`, so a shim pins every call to our own server and
# leaves the user's sessions alone.
cat > "$TMP_DIR/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
EOF
chmod +x "$TMP_DIR/bin/tmux"
export PATH="$TMP_DIR/bin:$PATH"

cleanup() {
    pkill -f "$REPO_DIR/scripts/sidebar-collector.sh" 2>/dev/null
    pkill -f "$REPO_DIR/scripts/sidebar.sh" 2>/dev/null
    "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null
    # The collector may still be mid-write when it is killed, so give it a
    # moment before removing the tree it is writing into.
    sleep 0.5
    rm -rf "$TMP_DIR" 2>/dev/null
}
trap cleanup EXIT

# CPU time actually consumed, in ms. ps %cpu averages over a process's whole
# lifetime, so a freshly spawned renderer reads high for minutes; the delta of
# cumulative time over a window is what the machine really spent.
cpu_ms() { ps -o time= -p "$1" 2>/dev/null | awk -F: '{print ($1*60+$2)*1000}'; }
sum_cpu() {
    local total=0 pid
    for pid in $(pgrep -f "$1" 2>/dev/null); do
        total=$((total + $(cpu_ms "$pid" 2>/dev/null || echo 0)))
    done
    echo "$total"
}

build_world() {
    tmux -f /dev/null new-session -d -s bench0 -x 200 -y 50 2>/dev/null
    local s w
    for s in $(seq 0 $((SESSIONS - 1))); do
        [ "$s" -gt 0 ] && tmux new-session -d -s "bench$s" -x 200 -y 50 2>/dev/null
        for w in $(seq 2 "$WINDOWS"); do
            tmux new-window -d -t "bench$s" -n "w$w" 2>/dev/null
        done
    done

    # Pin N agents in "working" through the documented file integration, so the
    # workload is identical on every run and no real agent is needed.
    local i sess
    for i in $(seq 1 "$AGENTS"); do
        sess="bench$(( (i - 1) % SESSIONS ))"
        echo working > "$STATUS_DIR/${sess}.status"
        echo working > "$STATUS_DIR/panes/${sess}_%$((100 + i)).status"
        echo claude  > "$STATUS_DIR/panes/${sess}_%$((100 + i)).agent"
    done
}

run_trial() {
    local r0 c0 r1 c1
    r0=$(sum_cpu "$REPO_DIR/scripts/sidebar.sh")
    c0=$(sum_cpu "$REPO_DIR/scripts/sidebar-collector.sh")
    sleep "$SAMPLE"
    r1=$(sum_cpu "$REPO_DIR/scripts/sidebar.sh")
    c1=$(sum_cpu "$REPO_DIR/scripts/sidebar-collector.sh")
    awk -v r0="$r0" -v r1="$r1" -v c0="$c0" -v c1="$c1" -v d="$SAMPLE" \
        'BEGIN{ printf "%.2f %.2f", (r1-r0)/(d*1000)*100, (c1-c0)/(d*1000)*100 }'
}

printf 'bench%s: %s sessions x %s windows, %s agents working, %s trials of %ss\n' \
    "${LABEL:+ [$LABEL]}" "$SESSIONS" "$WINDOWS" "$AGENTS" "$TRIALS" "$SAMPLE"
printf '  commit: %s\n' "$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

build_world
"$REPO_DIR/tmux-agent-status.tmux" >/dev/null 2>&1
sleep "$SETTLE"

# macOS pgrep has no -c, so count lines rather than trusting a flag that
# silently errors and reports zero.
printf '  renderers: %s   collector: %s\n' \
    "$(pgrep -f "$REPO_DIR/scripts/sidebar.sh" 2>/dev/null | wc -l | tr -d ' ')" \
    "$(pgrep -f "$REPO_DIR/scripts/sidebar-collector.sh" 2>/dev/null | wc -l | tr -d ' ')"

R_ALL=""; C_ALL=""
for t in $(seq 1 "$TRIALS"); do
    read -r rcpu ccpu <<< "$(run_trial)"
    printf '  trial %s: renderers %5s%%   collector %5s%%   total %5.2f%%\n' \
        "$t" "$rcpu" "$ccpu" "$(awk -v a="$rcpu" -v b="$ccpu" 'BEGIN{print a+b}')"
    R_ALL="$R_ALL $rcpu"; C_ALL="$C_ALL $ccpu"
done

awk -v r="$R_ALL" -v c="$C_ALL" 'BEGIN{
    n=split(r, ra, " "); split(c, ca, " ")
    for (i=1;i<=n;i++){ rs+=ra[i]; cs+=ca[i]; t=ra[i]+ca[i]; ts+=t
                        if(tmin==0||t<tmin)tmin=t; if(t>tmax)tmax=t }
    printf "  ---\n  mean: renderers %.2f%%  collector %.2f%%  TOTAL %.2f%% of one core\n", rs/n, cs/n, ts/n
    printf "  spread: %.2f%% .. %.2f%%  (differences smaller than this are noise)\n", tmin, tmax
}'
