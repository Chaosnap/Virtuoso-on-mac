#!/bin/zsh
# Virtuoso IC6.1.7 on macOS: OrbStack (linux/amd64 container) + XQuartz (X11).
# Virtuoso windows open directly on the Mac desktop: no VNC, no Linux desktop.
#
#   ./run_virtuoso.sh             OrbStack -> XQuartz -> container -> Virtuoso GUI, with the
#                                 CIW log shown here; the script ends when Virtuoso is closed.
#                                 If Virtuoso is already running, shows that session's log.
#   ./run_virtuoso.sh gui [DIR]   start another Virtuoso session (cwd DIR, default /root), same log view
#   ./run_virtuoso.sh shell       root shell in the container (cwd /workspace)
#   ./run_virtuoso.sh check       X11 / container / tool checks only
#   ./run_virtuoso.sh stop        stop the container
#   ./run_virtuoso.sh recreate    re-create the container (the old one is kept, renamed)
#
# Environment:
#   VIRTUOSO_SCALE=1.5            UI font scale 1.0 / 1.25 / 1.5 / 2.0, or off (image default: 1.5)
#   VIRTUOSO_IMAGE / VIRTUOSO_CONTAINER   override image / container name
#
# Ctrl-C (or closing the terminal) only stops the log view; Virtuoso keeps
# running, so unsaved designs are never lost that way.
#
# Virtuoso creates .cadence/, cds.lib etc. in its working directory, so the
# default session runs in /root (inside the container) and never writes to
# workspace/ on its own. Use `gui /workspace/projects/<name>` to work there.
set -euo pipefail

IMAGE="${VIRTUOSO_IMAGE:-virtuoso:ic617}"
CONTAINER_NAME="${VIRTUOSO_CONTAINER:-virtuoso-container}"
CONTAINER_HOSTNAME="virtuoso"
SCRIPT_NAME="$0"   # zsh: $0 inside a function is the function name
SCRIPT_DIR="${0:A:h}"
HOST_DIR="$SCRIPT_DIR/workspace"
# Copy of the XQuartz MIT-MAGIC-COOKIE for the container (private, outside workspace/)
XAUTH_DIR="$HOME/.cache/virtuoso-docker/xauth"
XAUTH_FILE="$XAUTH_DIR/Xauthority"
CONTAINER_XAUTH_DIR="/run/xauth"
X11_BIN="/opt/X11/bin"
DEFAULT_GUI_DIR="/root"
REAL_VIRTUOSO_BIN="/opt/cadence/IC617/tools/dfII/bin/64bit/virtuoso"

MODE="${1:-start}"
DISPLAY_NUM=0

# Runs inside the container (bash): starts or attaches to a Virtuoso session and
# prints its CDS.log like the CIW until that session exits.
#   $1 = launch | attach   $2 = file for the launch's stdout/stderr   $3 = 1 for colors
FOLLOW_SCRIPT="$(cat <<'IN_CONTAINER'
mode="$1"; out="$2"; color="$3"

# CDS.log* held open by process $1 or a direct child (each session keeps its own log open).
session_log() {
    local p fd f
    for p in "$1" $(pgrep -P "$1" 2>/dev/null); do
        for fd in /proc/"$p"/fd/*; do
            f="$(readlink "$fd" 2>/dev/null)" || continue
            case "$f" in */CDS.log|*/CDS.log.[0-9]*) echo "$f"; return 0 ;; esac
        done
    done
    return 1
}

# CDS.log -> CIW-like text: output, typed input (cyan), warnings (yellow), errors (red).
ciw_view() {
    awk -v color="$color" '
        function paint(code, s) { return color ? "\033[" code "m" s "\033[0m" : s }
        # harmless: Qt queries an X atom that XQuartz does not have, once at startup
        /BadAtom \(invalid Atom parameter\)/ || /^\\e  request 20 error 5 / { next }
        { tag = substr($0, 1, 2); text = substr($0, 4) }
        tag == "\\o" { print text; fflush(); next }
        tag == "\\i" { print paint("36", "> " text); fflush(); next }
        tag == "\\w" { print paint("33", text); fflush(); next }
        tag == "\\e" { print paint("31", text); fflush(); next }
        substr($0, 1, 1) != "\\" { print; fflush() }'
}

if [[ "$mode" == launch ]]; then
    # Own session, no stdin: terminal Ctrl-C/hangup never reaches Virtuoso.
    setsid -w /usr/local/bin/virtuoso </dev/null >"$out" 2>&1 &
    pid=$!
    log=""
    for _ in $(seq 240); do                 # first start under Rosetta can be slow
        log="$(session_log "$pid")" && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    files=("$out")
    [[ -n "$log" ]] && files+=("$log")
    tail -q -n +1 -F --pid="$pid" "${files[@]}" 2>/dev/null | ciw_view
    wait "$pid"
    exit $?
fi

# attach: follow the newest running session
log=""
for pid in $(ps -C virtuoso -o pid= --sort=-start_time); do
    log="$(session_log "$pid")" && break
done
[[ -n "$log" ]] || exit 3
echo "(log: $log, PID $pid)"
tail -n 30 -F --pid="$pid" "$log" 2>/dev/null | ciw_view
IN_CONTAINER
)"

info() { print -r -- "==> $*"; }
warn() { print -ru2 -- "WARNING: $*"; }
die()  { print -ru2 -- "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------- OrbStack
start_orbstack() {
    if ! docker info >/dev/null 2>&1; then
        info "Opening OrbStack"
        open -g -a OrbStack
        for _ in {1..60}; do
            docker info >/dev/null 2>&1 && break
            sleep 1
        done
    fi
    docker info >/dev/null 2>&1 || die "Docker Engine (OrbStack) is not ready."
    docker image inspect "$IMAGE" >/dev/null 2>&1 || die "Image not found: $IMAGE"
}

# ---------------------------------------------------------------- XQuartz
start_xquartz() {
    [[ -x "$X11_BIN/xset" && -x "$X11_BIN/xauth" ]] || die "XQuartz is not installed (missing $X11_BIN)."

    if ! pgrep -qx Xquartz; then
        # XQuartz is not running yet, so its settings can be fixed without
        # closing anyone's X11 windows: TCP listening + cookie authentication.
        if [[ "$(defaults read org.xquartz.X11 nolisten_tcp 2>/dev/null || echo 1)" != 0 ]]; then
            info "XQuartz: enabling 'Allow connections from network clients'"
            defaults write org.xquartz.X11 nolisten_tcp -bool false
        fi
        if [[ "$(defaults read org.xquartz.X11 no_auth 2>/dev/null || echo 0)" != 0 ]]; then
            info "XQuartz: enabling 'Authenticate connections'"
            defaults write org.xquartz.X11 no_auth -bool false
        fi
        info "Opening XQuartz"
        open -g -a XQuartz
    fi

    local local_display
    local_display="$(launchctl getenv DISPLAY || true)"
    [[ -n "$local_display" ]] || local_display=":0"
    DISPLAY_NUM="${${local_display##*:}%%.*}"

    for _ in {1..30}; do
        "$X11_BIN/xset" -display "$local_display" q >/dev/null 2>&1 && break
        sleep 1
    done
    "$X11_BIN/xset" -display "$local_display" q >/dev/null 2>&1 \
        || die "XQuartz did not start (display $local_display)."

    if ! nc -z -w 2 127.0.0.1 $((6000 + DISPLAY_NUM)) >/dev/null 2>&1; then
        die "XQuartz is not listening on TCP $((6000 + DISPLAY_NUM)).
       XQuartz > Settings > Security: enable 'Authenticate connections' and
       'Allow connections from network clients', then quit XQuartz (Cmd-Q) and rerun."
    fi
}

# Export the running server's cookie as a FamilyWild entry, so it matches
# "host.docker.internal:N" inside the container. No `xhost +` is used.
write_xauth() {
    local server_auth cookie tmp_local tmp_wild
    # Cookies the running server accepts: the file passed via `Xquartz :N ... -auth FILE`.
    server_auth="$(ps -axo args= | awk -v d=":$DISPLAY_NUM" \
        '$1 ~ /\/Xquartz$/ && $2 == d && !f { for (i = 3; i < NF; i++) if ($i == "-auth") { a = $(i + 1); f = 1 } }
         END { if (f) print a }')"
    if [[ -n "$server_auth" && -r "$server_auth" ]]; then
        cookie="$("$X11_BIN/xauth" -f "$server_auth" list 2>/dev/null | awk '$2 == "MIT-MAGIC-COOKIE-1" && !f { c = $3; f = 1 } END { if (f) print c }')"
    fi
    if [[ -z "${cookie:-}" ]]; then
        cookie="$("$X11_BIN/xauth" list ":$DISPLAY_NUM" 2>/dev/null | awk '$2 == "MIT-MAGIC-COOKIE-1" && !f { c = $3; f = 1 } END { if (f) print c }')"
    fi
    [[ -n "${cookie:-}" ]] || die "No MIT-MAGIC-COOKIE found for XQuartz :$DISPLAY_NUM ('Authenticate connections' must be on; restart XQuartz)."

    mkdir -p "$XAUTH_DIR"
    chmod 700 "$XAUTH_DIR"
    tmp_local="$(mktemp "$XAUTH_DIR/.local.XXXXXX")"
    tmp_wild="$(mktemp "$XAUTH_DIR/.wild.XXXXXX")"
    "$X11_BIN/xauth" -q -f "$tmp_local" add "$CONTAINER_HOSTNAME/unix:$DISPLAY_NUM" MIT-MAGIC-COOKIE-1 "$cookie"
    "$X11_BIN/xauth" -q -f "$tmp_local" nlist | sed -e 's/^..../ffff/' | "$X11_BIN/xauth" -q -f "$tmp_wild" nmerge -
    rm -f "$tmp_local"
    chmod 600 "$tmp_wild"
    mv -f "$tmp_wild" "$XAUTH_FILE"   # atomic; the container sees the directory mount

    # Prove the cookie works over TCP before involving the container.
    XAUTHORITY="$XAUTH_FILE" "$X11_BIN/xset" -display "127.0.0.1:$DISPLAY_NUM" q >/dev/null 2>&1 \
        || die "XQuartz rejected the exported cookie over TCP (try quitting and restarting XQuartz)."
}

# ---------------------------------------------------------------- container
container_exists() { docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; }

create_container() {
    [[ -d "$HOST_DIR" ]] || die "Workspace directory not found: $HOST_DIR"
    info "Creating container: $CONTAINER_NAME (hostname $CONTAINER_HOSTNAME)"
    docker create \
        --name "$CONTAINER_NAME" \
        --hostname "$CONTAINER_HOSTNAME" \
        --platform linux/amd64 \
        --init \
        --security-opt no-new-privileges \
        -e "DISPLAY=host.docker.internal:$DISPLAY_NUM" \
        -e "XAUTHORITY=$CONTAINER_XAUTH_DIR/Xauthority" \
        -v "${HOST_DIR}:/workspace" \
        -v "${XAUTH_DIR}:${CONTAINER_XAUTH_DIR}:ro" \
        -w /workspace \
        "$IMAGE" sleep infinity >/dev/null
}

check_existing_container() {
    local hostname mounts
    hostname="$(docker inspect -f '{{.Config.Hostname}}' "$CONTAINER_NAME")"
    mounts="$(docker inspect -f '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' "$CONTAINER_NAME")"
    if [[ "$hostname" != "$CONTAINER_HOSTNAME" \
          || " $mounts " != *" $HOST_DIR:/workspace "* \
          || " $mounts " != *" $XAUTH_DIR:$CONTAINER_XAUTH_DIR "* ]]; then
        die "Container '$CONTAINER_NAME' uses old settings (VNC era: hostname '$hostname').
       Re-create it (the old one is kept, renamed):  $SCRIPT_NAME recreate"
    fi
    if [[ "$(docker inspect -f '{{.Image}}' "$CONTAINER_NAME")" != "$(docker image inspect -f '{{.Id}}' "$IMAGE")" ]]; then
        warn "Container was created from an older '$IMAGE'. To switch: $SCRIPT_NAME recreate"
    fi
}

ensure_container() {
    if container_exists; then
        check_existing_container
    else
        create_container
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" != "true" ]]; then
        info "Starting container: $CONTAINER_NAME"
        docker start "$CONTAINER_NAME" >/dev/null
    fi
    if ! docker exec -e "DISPLAY=host.docker.internal:$DISPLAY_NUM" "$CONTAINER_NAME" \
            timeout 20 xset q >/dev/null 2>&1; then
        die "Container cannot open DISPLAY host.docker.internal:$DISPLAY_NUM.
       Check: docker exec $CONTAINER_NAME bash -lc 'ls -l $CONTAINER_XAUTH_DIR; xset q'"
    fi
    info "X11 OK: $CONTAINER_NAME -> host.docker.internal:$DISPLAY_NUM (XQuartz, cookie auth)"
}

recreate_container() {
    if container_exists; then
        local backup_name changes running
        backup_name="${CONTAINER_NAME}-old-$(date +%Y%m%d-%H%M%S)"
        info "Existing container: $CONTAINER_NAME ($(docker inspect -f '{{.Config.Hostname}} / {{.State.Status}}' "$CONTAINER_NAME"))"
        # Files that exist only inside the container (workspace/ is a bind mount and is not affected).
        changes="$(docker diff "$CONTAINER_NAME" | grep -vE '^[ACD] /(tmp|run|proc|dev|var/tmp|var/run)(/|$)' || true)"
        if [[ -n "$changes" ]]; then
            print "Files changed inside the container (not in workspace/):"
            local -a change_lines=("${(@f)changes}")
            print -rl -- "${(@)change_lines[1,40]}"
            if (( ${#change_lines} > 40 )); then
                print "  ... (${#change_lines} entries in total)"
            fi
        fi
        running="$(docker exec "$CONTAINER_NAME" pgrep -fl 'dfII/bin/64bit/(virtuoso|libManager)' 2>/dev/null || true)"
        if [[ -n "$running" ]]; then
            warn "Virtuoso is running in this container and will be stopped (save your work first):"
            print -r -- "$running"
        fi
        print "The old container is NOT deleted: it is stopped and renamed to '$backup_name'."
        print "Copy files out later with: docker cp $backup_name:/root/<file> ."
        if ! read -q "?Continue? [y/N] "; then
            print; die "Cancelled."
        fi
        print
        docker stop "$CONTAINER_NAME" >/dev/null
        docker rename "$CONTAINER_NAME" "$backup_name"
        info "Old container kept as: $backup_name  (remove when no longer needed: docker rm $backup_name)"
    fi
    create_container
}

# ---------------------------------------------------------------- actions
# Virtuoso in the foreground of this terminal, like Vivado: the CIW log is shown
# here and the function returns (with Virtuoso's exit status) when it is closed.
#   $1 = launch (new session, cwd $2) | attach (follow the running session)
virtuoso_foreground() {
    local mode="$1" workdir="${2:-$DEFAULT_GUI_DIR}" out color=0 rc=0
    local -a exec_args=()
    if [[ -t 0 && -t 1 ]]; then
        exec_args=(-it)       # forwards Ctrl-C to the log view inside the container
        color=1
    fi
    out="/tmp/virtuoso-$(date +%Y%m%d-%H%M%S).out"
    if [[ "$mode" == launch ]]; then
        docker exec "$CONTAINER_NAME" test -d "$workdir" || die "Directory not found in container: $workdir"
        exec_args+=(-w "$workdir" -e "DISPLAY=host.docker.internal:$DISPLAY_NUM")
        if [[ -n "${VIRTUOSO_SCALE:-}" ]]; then
            exec_args+=(-e "VIRTUOSO_SCALE=$VIRTUOSO_SCALE")
        fi
        info "Launching Virtuoso (cwd $workdir, scale ${VIRTUOSO_SCALE:-image default}); the CIW opens on the Mac shortly"
    else
        info "Virtuoso is already running; showing its log ('$SCRIPT_NAME gui' starts another session)"
    fi
    info "Close Virtuoso to end this script. Ctrl-C only stops the log view."
    docker exec "${exec_args[@]}" "$CONTAINER_NAME" /bin/bash -lc "$FOLLOW_SCRIPT" follow "$mode" "$out" "$color" || rc=$?
    case $rc in
        0)   info "Virtuoso exited." ;;
        3)   warn "No Virtuoso log found to follow." ;;
        130) print; info "Log view stopped; Virtuoso is still running. Show its log again: $SCRIPT_NAME" ;;
        *)   warn "Virtuoso exited with status $rc (launch output: docker exec $CONTAINER_NAME cat $out)" ;;
    esac
    return $rc
}

virtuoso_running() {
    docker exec "$CONTAINER_NAME" pgrep -f "$REAL_VIRTUOSO_BIN" >/dev/null 2>&1
}

open_shell() {
    local -a tty_args=(-i)
    [[ -t 0 && -t 1 ]] && tty_args=(-it)
    docker exec "${tty_args[@]}" -w /workspace -e "DISPLAY=host.docker.internal:$DISPLAY_NUM" \
        "$CONTAINER_NAME" /bin/bash -l
}

run_checks() {
    docker exec -e "DISPLAY=host.docker.internal:$DISPLAY_NUM" "$CONTAINER_NAME" /bin/bash -lc '
        printf "%-16s %s\n" hostname "$(hostname)"
        printf "%-16s %s\n" prompt "$(bash -ic "printf %s \"\${PS1@P}\"" 2>/dev/null)"
        printf "%-16s %s\n" DISPLAY "$DISPLAY"
        printf "%-16s %s\n" XAUTHORITY "$XAUTHORITY"
        printf "%-16s %s\n" "X11 (xset q)" "$(timeout 20 xset q >/dev/null 2>&1 && echo OK || echo FAILED)"
        printf "%-16s %s\n" "X screen" "$(timeout 20 xrandr 2>/dev/null | sed -n "s/^Screen 0: .*current \([0-9]* x [0-9]*\).*/\1/p")"
        printf "%-16s %s\n" VIRTUOSO_SCALE "${VIRTUOSO_SCALE:-<unset>}"
        printf "%-16s %s\n" "virtuoso (PATH)" "$(command -v virtuoso)"
        for f in /opt/cadence/IC617/tools/dfII/bin/virtuoso /opt/cadence/IC617/tools/dfII/bin/64bit/virtuoso \
                 "$(command -v spectre)" "$(command -v calibre)"; do
            printf "%-16s %s\n" "$(basename "$f")" "$( [ -e "$f" ] && echo "present: $f" || echo "MISSING: $f")"
        done'
}

# ---------------------------------------------------------------- main
case "$MODE" in
    start|gui|shell|check|recreate) ;;
    stop)
        docker stop "$CONTAINER_NAME" >/dev/null
        info "Stopped $CONTAINER_NAME"
        exit 0 ;;
    -h|--help|help)
        awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *)
        die "Unknown command '$MODE' (start | gui [DIR] | shell | check | stop | recreate)" ;;
esac

start_orbstack
start_xquartz
write_xauth
if [[ "$MODE" == recreate ]]; then
    recreate_container
fi
ensure_container

case "$MODE" in
    start)
        if virtuoso_running; then
            virtuoso_foreground attach
        else
            virtuoso_foreground launch "$DEFAULT_GUI_DIR"
        fi ;;
    gui)      virtuoso_foreground launch "${2:-$DEFAULT_GUI_DIR}" ;;
    shell)    open_shell ;;
    check)    run_checks ;;
    recreate) info "Container re-created. Start Virtuoso with: $SCRIPT_NAME" ;;
esac
