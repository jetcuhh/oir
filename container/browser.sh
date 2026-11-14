#!/usr/bin/env bash
# Headless Wayland desktop (sway + Chromium) streamed out over VNC.
#
#   wayland-browser start|stop|restart|status|shot [url]
#
# No X11 anywhere: sway runs on the wlroots headless backend and Chromium uses
# --ozone-platform=wayland, so this needs no /dev/dri, no Xvfb and no Xwayland.
set -euo pipefail

LOG="${LOG:-/tmp/wayland-remote}"
RES="${RES:-1440x900}"
VNC_PORT="${VNC_PORT:-5900}"
PROFILE="${PROFILE:-$HOME/.cache/chromium-wayland}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-$(id -u)}"

mkdir -p "$LOG" "$PROFILE" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

die() { echo "error: $*" >&2; exit 1; }

# PID 1 in this container is `sleep infinity`, so nothing reaps orphans and
# killed processes stay around as zombies. `pgrep` matches those, so filter
# out the Z state or every restart looks like "already running".
# (stat is the first column on purpose: a long comm such as `<defunct>` spills
# into the next field and shifts everything to the right.)
alive() {
    ps -eo stat=,comm= | awk -v c="$1" '$1 !~ /^Z/ && $2 == c { f = 1 } END { exit !f }'
}

wayland_socket() {
    basename "$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -1)"
}

launch_browser() {
    local url="${1:-${BROWSER_URL:-https://example.com}}"
    export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-$(wayland_socket)}"
    setsid chromium --no-sandbox --disable-gpu --disable-dev-shm-usage \
        --no-first-run --no-default-browser-check --disable-search-engine-choice-screen \
        --password-store=basic --ozone-platform=wayland --start-maximized \
        --user-data-dir="$PROFILE" "$url" \
        >>"$LOG/chromium.log" 2>&1 </dev/null &
}

start() {
    local url="${1:-${BROWSER_URL:-https://example.com}}"

    if alive sway; then
        if ! alive chromium; then
            launch_browser "$url"
            sleep 2
            echo "compositor was up, browser relaunched (vnc on 0.0.0.0:$VNC_PORT)"
            return 0
        fi
        echo "already running (vnc on 0.0.0.0:$VNC_PORT)"
        return 0
    fi

    export WLR_BACKENDS=headless
    export WLR_HEADLESS_OUTPUTS=1
    export WLR_LIBINPUT_NO_DEVICES=1
    export WLR_RENDERER=pixman
    export LIBGL_ALWAYS_SOFTWARE=1
    export XDG_SESSION_TYPE=wayland
    export XDG_CURRENT_DESKTOP=sway

    # sway 'exec' lines run with WAYLAND_DISPLAY already correct.
    cat >"$LOG/sway.conf" <<CONF
output HEADLESS-1 resolution $RES
output HEADLESS-1 bg '#11111b' solid_color
exec wayvnc 0.0.0.0 $VNC_PORT -f ${VNC_MAX_FPS:-30} -p -L info
exec chromium --no-sandbox --disable-gpu --disable-dev-shm-usage \
  --no-first-run --no-default-browser-check --disable-search-engine-choice-screen \
  --password-store=basic --ozone-platform=wayland --start-maximized \
  --user-data-dir='$PROFILE' '$url'
CONF

    setsid sway -c "$LOG/sway.conf" --unsupported-gpu \
        >"$LOG/sway.log" 2>&1 </dev/null &

    # wait for the VNC port
    local i
    for i in $(seq 1 40); do
        ss -lnt 2>/dev/null | grep -q ":$VNC_PORT " && break
        sleep 0.25
    done
    ss -lnt 2>/dev/null | grep -q ":$VNC_PORT " \
        || die "wayvnc never bound :$VNC_PORT (see $LOG/sway.log)"

    echo "started: $url on 0.0.0.0:$VNC_PORT (log: $LOG/sway.log)"
}

stop() {
    pkill -x sway 2>/dev/null || true
    pkill -x wayvnc 2>/dev/null || true
    pkill -x chromium 2>/dev/null || true
    pkill -x swaybg 2>/dev/null || true
    sleep 1
    rm -f "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null || true
    echo "stopped"
}

status() {
    if alive sway; then
        echo "compositor: sway (headless, $(alive chromium && echo 'chromium up' || echo 'no browser'))"
        ss -lnt 2>/dev/null | grep ":$VNC_PORT " || echo "vnc:        not listening"
    else
        echo "not running"
        return 1
    fi
}

shot() {
    local out="${1:-$LOG/shot.png}"
    command -v grim >/dev/null || die "grim not installed"
    export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -1)")}"
    grim "$out"
    echo "$out"
}

case "${1:-status}" in
    start)   shift; start "$@" ;;
    stop)    stop ;;
    restart) stop; shift; start "$@" ;;
    status)  status ;;
    shot)    shift; shot "$@" ;;
    *)       echo "usage: wayland-browser start|stop|restart|status|shot [url|out.png]" >&2; exit 2 ;;
esac
