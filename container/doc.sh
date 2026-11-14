#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_NAME="jetdafih"
CONTAINER_NAME="jetdafih"
START_DIR="/home/jet/dev"
LOCK_FILE="${TMPDIR:-/tmp}/oir.lock"
SHARE_DIR="$HOME/dev"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
doc.sh - build/start the Oir container and open a shell in it.

  ./doc.sh             start (or resume) the container and attach
  ./doc.sh --reset     delete the container (files outside ~/dev are lost), then start fresh
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
        procps-ng croc  chafa libcap ripgrep fd && \
    pacman -Scc --noconfirm

# Zig is pinned: unn needs 0.17.0 and the Arch package lags.
ARG ZIG_VERSION=0.17.0
RUN z="zig-$(uname -m)-linux-$ZIG_VERSION" && \
    curl --proto '=https' --tlsv1.2 -fsSL "https://ziglang.org/download/$ZIG_VERSION/$z.tar.xz" | tar -xJ -C /opt && \
    ln -s "/opt/$z/zig" /usr/local/bin/zig

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
ENV RIPGREP_CONFIG_PATH="/home/jet/.config/ripgreprc"
ENV PATH="/home/jet/.opencode/bin:/home/jet/.local/bin:/home/jet/.cargo/bin:${PATH}"

RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent freebuff  pnpm && \
    curl -fsSL https://opencode.ai/v2/install | bash -s -- --no-modify-path

RUN pi install npm:@maxpaulus/pi-cline

RUN mkdir -p /home/jet/.config/fish && \
    cat >> /home/jet/.config/fish/config.fish <<'FISHEOF'
set -g fish_greeting
fish_config prompt choose arrow >/dev/null

# The web terminal names each tab after the shell's title: show just the directory.
function fish_title
    if test "$PWD" = "$HOME"
        echo "~"
    else
        basename "$PWD"
    end
end
set -gx JAVA_HOME /usr/lib/jvm/default
alias ls 'eza --color=always --icons=always --group-directories-first'

if status is-interactive
    test -n "$GIT_NAME"; and git config --global user.name "$GIT_NAME"
    test -n "$GIT_EMAIL"; and git config --global user.email "$GIT_EMAIL"

    if test -n "$GITHUB_TOKEN"
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
RUN curl -fsSL https://raw.githubusercontent.com/jetdafih/dpath/main/install.sh | sh -s -- both

RUN curl -fsSL https://raw.githubusercontent.com/jetdafih/lantern/main/install.sh | sh

# oshi and flint: build from source, install into ~/.local/bin, delete the checkout.
RUN git clone --depth 1 https://github.com/jetdafih/oshi /tmp/oshi \
    && make -C /tmp/oshi install \
    && rm -rf /tmp/oshi

RUN git clone --depth 1 https://github.com/jetdafih/flint /tmp/flint \
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
    echo "Image built."
  fi

  if ! docker container inspect "$CONTAINER_NAME" &>/dev/null; then
    mkdir -p "$SHARE_DIR"
    echo "Starting container..."
    docker run -d --name "$CONTAINER_NAME" \
      --hostname fridge \
      --init \
      -p 127.0.0.1:5900:5900 \
      -u jet \
      -v "$SHARE_DIR:/home/jet/dev" \
      "$IMAGE_NAME" >/dev/null
  else
    if ! docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$CONTAINER_NAME" 2>/dev/null \
         | grep -q '/home/jet/dev'; then
      echo "WARNING: this container predates the ~/dev share mount; run --reset to recreate it." >&2
    fi
  fi

  docker start "$CONTAINER_NAME" >/dev/null

  # Sway, wayvnc and Chromium stay installed but are NOT started. The helper is
  # copied in so `wayland-browser start` works on demand inside the container;
  # set BROWSER=1 to start it on every attach instead.
  if [ -f "$HERE/browser.sh" ]; then
    docker cp "$HERE/browser.sh" \
      "$CONTAINER_NAME:/home/jet/.local/bin/wayland-browser" >/dev/null 2>&1 || true
    docker exec -u jet "$CONTAINER_NAME" \
      chmod +x /home/jet/.local/bin/wayland-browser >/dev/null 2>&1 || true
    if [ "${BROWSER:-0}" = "1" ]; then
      docker exec -u jet -e VNC_PORT="${VNC_PORT:-5900}" -e RES="${RES:-1440x900}" \
        "$CONTAINER_NAME" /home/jet/.local/bin/wayland-browser start \
        >/dev/null 2>&1 || true
    fi
  fi

  # File helpers for Claude (rd, edit, wr, gl, tools) + ripgrep defaults.
  if [ -d "$HERE/bin" ]; then
    docker exec -u jet "$CONTAINER_NAME" mkdir -p /home/jet/.config /home/jet/.local/bin >/dev/null 2>&1 || true
    docker cp "$HERE/bin/ripgreprc" "$CONTAINER_NAME:/home/jet/.config/ripgreprc" >/dev/null 2>&1 || true
    for f in rd edit wr gl tools handoff commit-msg swayrun chromiumoir; do
      docker cp "$HERE/bin/$f" "$CONTAINER_NAME:/home/jet/.local/bin/$f" >/dev/null 2>&1 || true
    done
    # Git: strip AI attribution from commits, and set an identity so commits work everywhere.
    docker exec -u jet -e GITHUB_TOKEN -e GIT_NAME -e GIT_EMAIL "$CONTAINER_NAME" bash -c '
      mkdir -p ~/.config/git/hooks && cp ~/.local/bin/commit-msg ~/.config/git/hooks/commit-msg
      chmod +x ~/.config/git/hooks/commit-msg ~/.local/bin/{rd,edit,wr,gl,tools,handoff,commit-msg}
      git config --global core.hooksPath ~/.config/git/hooks
      n="${GIT_NAME:-}"; e="${GIT_EMAIL:-}"
      if [ -z "$n$e" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
        i="$(gh api user --jq "[.id,.login,(.name // .login)]|@tsv" 2>/dev/null)"
        if [ -n "$i" ]; then IFS="	" read -r id login name <<<"$i"; n="$name"; e="$id+$login@users.noreply.github.com"; fi
      fi
      [ -z "$n" ] || git config --global user.name "$n"
      [ -z "$e" ] || git config --global user.email "$e"
    ' >/dev/null 2>&1 || true
    docker exec -u jet "$CONTAINER_NAME" chmod +x \
      /home/jet/.local/bin/{rd,edit,wr,gl,tools,handoff,commit-msg} >/dev/null 2>&1 || true
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

export GIT_NAME="${GIT_NAME:-JetFih}"
export GIT_EMAIL="${GIT_EMAIL:-279371027+jetdafih@users.noreply.github.com}"

attach() {
  local tty_flags=(-i)
  if [ -t 0 ] && [ -t 1 ]; then
    tty_flags=(-it)
  fi
  exec docker exec "${tty_flags[@]}" \
    -u jet \
    -w "$START_DIR" \
    -e GITHUB_TOKEN \
    -e GIT_NAME \
    -e GIT_EMAIL \
    -e COLORTERM=truecolor \
    -e SHELL=/usr/bin/fish \
    "$CONTAINER_NAME" /usr/bin/fish
}

# Everything below the fast path only has to happen once per container. Once it has
# run it leaves this marker inside the container, and every later tab is a single
# `docker exec` away (a --reset or --rebuild deletes the container, marker included).
READY_MARK="/tmp/.oir-ready"
if docker exec -u jet "$CONTAINER_NAME" test -f "$READY_MARK" >/dev/null 2>&1; then
  if [ "$ACTION" = "prebuild" ]; then
    echo "Oir container is ready."
    exit 0
  fi
  attach
fi

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "WARNING: no TOKEN / GITHUB_TOKEN in this shell and no ~/.token file; gh/git will be unauthenticated." >&2
fi

ensure_container

docker exec -u jet "$CONTAINER_NAME" mkdir -p /home/jet/.agents >/dev/null 2>&1 || true

# Notes for the agents inside the container: any *.md next to this repo.
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

docker exec -u jet "$CONTAINER_NAME" touch "$READY_MARK" >/dev/null 2>&1 || true

if [ "$ACTION" = "prebuild" ]; then
  echo "Oir container is ready."
  exit 0
fi

attach
