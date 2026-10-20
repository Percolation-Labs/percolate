# TWO QUESTIONS ABOUT THE MACHINE, asked before a script starts work it cannot
# finish (REM-1017), sourced by dev/build-image.sh and dev/ci-database.sh.
#
# WHAT WENT WRONG. A full disk never says so. On 2026-10-19 about 17:00Z the Mac
# had 4 GiB free: Docker hung, two gates went red for causes that were not
# theirs, and four sessions lost half an hour between them reading those reds
# as test failures. 2026-09-18 was the same at 100%, and the postmortems count
# four instances. Separately, two parser builds at once on an 8 GB VM is an OOM,
# and that too shows up as a failure of whatever else was running.
#
# Both checks refuse at the start, with the figure, rather than failing later
# as something else.

# Refuse below MIN_FREE_GIB (default 10) on the filesystem holding $1, and on
# Docker's root directory when the daemon's disk is this machine's (a Linux
# runner; Docker Desktop keeps it inside a VM image on the host volume, which
# the first check covers).
require_free_disk() {
    local min="${MIN_FREE_GIB:-10}" dir free
    for dir in "$1" "$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)"; do
        [ -n "$dir" ] && [ -d "$dir" ] || continue
        free=$(df -Pk "$dir" | awk 'NR == 2 {printf "%d", $4 / 1048576}')
        if [ "$free" -lt "$min" ]; then
            echo "refusing to start: ${free} GiB free on $(df -P "$dir" | awk 'NR == 2 {print $6}')" \
                 "(needs ${min}; MIN_FREE_GIB overrides). A full disk fails as something else:" \
                 "check docker ps -a and old worktrees first." >&2
            return 1
        fi
    done
}

# One parser build per machine. mkdir is atomic on every filesystem, so it is
# the lock; the pid inside lets a build that was killed be told from one that
# is running, and its lock taken over instead of refusing forever.
# /tmp, not $TMPDIR: sessions on one machine can have different TMPDIRs.
PARSER_LOCK="${PARSER_LOCK:-/tmp/percolate-parser-build.lock}"
take_parser_lock() {
    if ! mkdir "$PARSER_LOCK" 2>/dev/null; then
        local pid
        pid=$(cat "$PARSER_LOCK/pid" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "refusing to start: a parser build is already running on this machine" \
                 "(pid $pid, $PARSER_LOCK). Two at once run an 8 GB VM out of memory." >&2
            return 1
        fi
        echo "==> taking over a stale parser lock (pid ${pid:-unknown} is gone)"
        rm -rf "$PARSER_LOCK"
        mkdir "$PARSER_LOCK" || return 1
    fi
    echo $$ > "$PARSER_LOCK/pid"
    trap 'rm -rf "$PARSER_LOCK"' EXIT
}
