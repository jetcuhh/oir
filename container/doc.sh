#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_NAME="jetcuhh"
CONTAINER_NAME="jetcuhh"
START_DIR="/home/jet/dev"
LOCK_FILE="${TMPDIR:-/tmp}/mono.dev.lock"
SHARE_DIR="$HOME/dev"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
doc.sh - build/start the Oir container and open a shell in it.

  ./doc.sh             start (or resume) the container and attach
  ./doc.sh --reset     delete the container (files inside are lost), then start fresh
  ./doc.sh --rebuild   delete the container AND the image, then rebuild everything
  ./doc.sh --prebuild  build the image and start the container, but don't attach
USAGE
}

ACTION=attach
case "${1:-}" in
  "")
    ;;
  --reset)
    docker rm -f "$CONTAINER_NAME" &>/dev/null || true
    ;;
  --rebuild)
    docker rm -f "$CONTAINER_NAME" &>/dev/null || true
    docker rmi -f "$IMAGE_NAME" &>/dev/null || true
    ;;
  --prebuild)
    ACTION=prebuild
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown option: $1 (try --help)" >&2
    exit 2
    ;;
esac

build_image() {
  # ~/dev is bind-mounted from the runner, so the container user must have the
  # runner's uid or neither side can write the other's files (no chown needed).
  local host_uid
  host_uid="$(id -u)"
  [ "$host_uid" -ne 0 ] || host_uid=1000
  docker build -t "$IMAGE_NAME" --build-arg HOST_UID="$host_uid" - <<'EOF'
FROM archlinux:latest

RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm base-devel git gcc fish nushell eza sudo curl github-cli ouch \
        nodejs npm \
        jdk21-openjdk jdk25-openjdk \
        sway wayvnc grim chromium mesa libglvnd wl-clipboard swaybg ttf-dejavu \
        procps-ng  chafa libcap && \
    pacman -Scc --noconfirm

# sway ships with cap_sys_nice=ep; Docker's capability bounding set rejects that
# at execve ("Operation not permitted"), so drop it. sway runs fine without it.
RUN setcap -r /usr/bin/sway

RUN archlinux-java set java-25-openjdk

ARG HOST_UID=1000
RUN useradd -m -u "$HOST_UID" -G wheel -s /usr/bin/fish jet && \
    echo "jet ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/jet && \
    chmod 440 /etc/sudoers.d/jet

USER jet
WORKDIR /home/jet

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable

ENV NPM_CONFIG_PREFIX="/home/jet/.local"
ENV PATH="/home/jet/.opencode/bin:/home/jet/.local/bin:/home/jet/.cargo/bin:${PATH}"

RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent pnpm && \
    curl -fsSL https://opencode.ai/v2/install | bash -s -- --no-modify-path

RUN pi install npm:@maxpaulus/pi-cline

RUN mkdir -p /home/jet/.config/fish && \
    cat >> /home/jet/.config/fish/config.fish <<'FISHEOF'
fish_config prompt choose arrow >/dev/null
set -gx JAVA_HOME /usr/lib/jvm/default
alias ls 'eza --color=always --icons=always --group-directories-first'

if status is-interactive
    test -n "$GIT_NAME"; and git config --global user.name "$GIT_NAME"
    test -n "$GIT_EMAIL"; and git config --global user.email "$GIT_EMAIL"

    if test -n "$GITHUB_TOKEN"
        gh auth setup-git --hostname github.com

        if not git config --global user.name >/dev/null; or not git config --global user.email >/dev/null
            set -l info (gh api user --jq '[.id, .login, (.name // .login)] | @tsv' 2>/dev/null)
            if test -n "$info"
                set -l parts (string split \t -- $info)
                git config --global user.name >/dev/null; or git config --global user.name "$parts[3]"
                git config --global user.email >/dev/null; or git config --global user.email "$parts[1]+$parts[2]@users.noreply.github.com"
            else
                echo "jet: couldn't fetch GitHub user (bad token?); git identity not fully set"
            end
        end
    else
        echo "jet: no GITHUB_TOKEN in this shell; gh/git are unauthenticated"
    end
end
FISHEOF

RUN mkdir -p /home/jet/.config/nushell /home/jet/.local/bin && \
    cat >> /home/jet/.config/nushell/env.nu <<'NUENVEOF'

$env.PATH = ($env.PATH | prepend $"($env.HOME)/.local/bin")
$env.JAVA_HOME = "/usr/lib/jvm/default"
NUENVEOF

RUN cat >> /home/jet/.config/nushell/config.nu <<'NUEOF'

alias ls = eza --color=always --icons=always --group-directories-first

$env.config.keybindings = ($env.config.keybindings | append [
  {
    name: delete_word_backward_backspace
    modifier: control
    keycode: backspace
    mode: [emacs, vi_normal, vi_insert]
    event: { edit: BackspaceWord }
  }
  {
    name: delete_word_backward_char_h
    modifier: control
    keycode: char_h
    mode: [emacs, vi_normal, vi_insert]
    event: { edit: BackspaceWord }
  }
])
NUEOF

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN curl -fsSL https://x.ai/cli/install.sh | bash

# dpath: there is no TTY during a build, so name the shells explicitly instead
# of letting the installer try to show its picker.
RUN curl -fsSL https://raw.githubusercontent.com/jetcuhh/dpath/main/install.sh | sh -s -- both

RUN curl -fsSL https://raw.githubusercontent.com/jetcuhh/lantern/main/install.sh | sh

# oshi and flint: build from source, install into ~/.local/bin, delete the checkout.
RUN git clone --depth 1 https://github.com/jetcuhh/oshi /tmp/oshi \
    && make -C /tmp/oshi install \
    && rm -rf /tmp/oshi

RUN git clone --depth 1 https://github.com/jetcuhh/flint /tmp/flint \
    && make -C /tmp/flint install \
    && rm -rf /tmp/flint

RUN mkdir -p /home/jet/dev
WORKDIR /home/jet/dev

CMD ["sleep", "infinity"]
EOF
}

ensure_container() {
  exec 9>"$LOCK_FILE"
  if command -v flock >/dev/null 2>&1; then
    flock 9
  fi

  if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "Building image '$IMAGE_NAME' (first run takes a few minutes)..."
    build_image
  fi

  if ! docker container inspect "$CONTAINER_NAME" &>/dev/null; then
    mkdir -p "$SHARE_DIR"
    docker run -d --name "$CONTAINER_NAME" \
      --hostname fridge \
      --init \
      -p 127.0.0.1:5900:5900 \
      -u jet \
      -v "$SHARE_DIR:/home/jet/dev" \
      "$IMAGE_NAME" >/dev/null
    echo "Created container '$CONTAINER_NAME'"
  else
    echo "Resuming existing container '$CONTAINER_NAME' (use --reset for a fresh one)"
    if ! docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$CONTAINER_NAME" 2>/dev/null \
         | grep -q '/home/jet/dev'; then
      echo "WARNING: this container predates the ~/dev share mount; run --reset to recreate it." >&2
    fi
  fi

  docker start "$CONTAINER_NAME" >/dev/null

  # Headless Wayland browser, reachable over VNC through an SSH tunnel.
  # Browser runs as a detached wlroots session; safe to call on every start.
  if [ "${BROWSER:-1}" != "0" ] && [ -f "$HERE/browser.sh" ]; then
    docker cp "$HERE/browser.sh" \
      "$CONTAINER_NAME:/home/jet/.local/bin/wayland-browser" >/dev/null 2>&1 || true
    docker exec -u jet "$CONTAINER_NAME" \
      chmod +x /home/jet/.local/bin/wayland-browser >/dev/null 2>&1 || true
    docker exec -u jet -e VNC_PORT="${VNC_PORT:-5900}" -e RES="${RES:-1440x900}" \
      "$CONTAINER_NAME" /home/jet/.local/bin/wayland-browser start \
      >/dev/null 2>&1 || true
  fi

  exec 9>&-
}

if [ -n "${TOKEN:-}" ]; then
  export GITHUB_TOKEN="$TOKEN"
fi

if [ -z "${GITHUB_TOKEN:-}" ] && [ -r "$HOME/.token" ]; then
  GITHUB_TOKEN="$(tr -d '[:space:]' < "$HOME/.token")"
  export GITHUB_TOKEN
fi

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "WARNING: no TOKEN / GITHUB_TOKEN in this shell and no ~/.token file; gh/git will be unauthenticated." >&2
else
  echo "GitHub token found, passing it into the shell."
fi

export GIT_NAME="${GIT_NAME:-}"
export GIT_EMAIL="${GIT_EMAIL:-}"
export LAPTOP_HOST="${LAPTOP_HOST:-}"
export LAPTOP_USER="${LAPTOP_USER:-}"

ensure_container

docker exec -u jet "$CONTAINER_NAME" mkdir -p /home/jet/.agents >/dev/null 2>&1 || true
docker exec -u jet "$CONTAINER_NAME" rm -f /home/jet/LAPTOP >/dev/null 2>&1 || true

# Tell the agent inside the container where the laptop is and how to move files.
printf 'laptop: %s (user %s)\nshare: /home/jet/dev  <- mounted from ~/dev on the runner\nlaptop -> container: ./connect.sh push <path>   (run on the laptop)\ncontainer -> laptop: ./connect.sh pull <name>   (run on the laptop)\n' \
  "${LAPTOP_HOST:-unknown}" "${LAPTOP_USER:-unknown}" \
  | docker exec -i -u jet "$CONTAINER_NAME" sh -c 'cat > /home/jet/.agents/LAPTOP' 2>/dev/null || true

for md in "$HERE"/../*.md; do
  [ -f "$md" ] || continue
  docker exec -i -u jet "$CONTAINER_NAME" \
    sh -c 'cat > "/home/jet/.agents/$1"' _ "$(basename "$md")" \
    < "$md" >/dev/null 2>&1 || true
done

# Point git at gh's credential helper for every shell, not just interactive fish.
if [ -n "${GITHUB_TOKEN:-}" ]; then
  docker exec -u jet -e GITHUB_TOKEN -e GH_TOKEN "$CONTAINER_NAME" \
    gh auth setup-git --hostname github.com >/dev/null 2>&1 || true
fi

if [ "$ACTION" = "prebuild" ]; then
  echo "Oir container is ready."
  exit 0
fi

TTY_FLAGS=(-i)
if [ -t 0 ] && [ -t 1 ]; then
  TTY_FLAGS=(-it)
fi

exec docker exec "${TTY_FLAGS[@]}" \
  -u jet \
  -w "$START_DIR" \
  -e GITHUB_TOKEN \
  -e GIT_NAME \
  -e GIT_EMAIL \
  -e LAPTOP_HOST \
  -e LAPTOP_USER \
  -e SHELL=/usr/bin/fish \
  "$CONTAINER_NAME" /home/jet/.local/bin/lantern
