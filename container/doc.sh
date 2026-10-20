#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_NAME="plinth-arch"
CONTAINER_NAME="plinth-dev"
START_DIR="/home/plinth/oshi"
LOCK_FILE="${TMPDIR:-/tmp}/${CONTAINER_NAME}.lock"

OWNER="${GITHUB_REPOSITORY_OWNER:-}"
if [ -z "$OWNER" ]; then
  OWNER="$(git -C "$(dirname "$0")" remote get-url origin 2>/dev/null | sed -E 's#.*[:/]([^/]+)/[^/]+$#\1#' || true)"
fi

usage() {
  cat <<'USAGE'
doc.sh - build/start the Arch dev container and open a shell in it.

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
  docker build -t "$IMAGE_NAME" --build-arg "OWNER=$OWNER" - <<'EOF'
FROM archlinux:latest

RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm base-devel git gcc fish nushell eza sudo curl github-cli \
        nodejs npm \
        jdk21-openjdk jdk25-openjdk && \
    pacman -Scc --noconfirm

RUN archlinux-java set java-25-openjdk

RUN useradd -m -G wheel -s /usr/bin/fish plinth && \
    echo "plinth ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/plinth && \
    chmod 440 /etc/sudoers.d/plinth

USER plinth
WORKDIR /home/plinth

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable

ENV NPM_CONFIG_PREFIX="/home/plinth/.local"
ENV PATH="/home/plinth/.opencode/bin:/home/plinth/.local/bin:/home/plinth/.cargo/bin:${PATH}"

RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent pnpm && \
    curl -fsSL https://opencode.ai/v2/install | bash -s -- --no-modify-path

RUN mkdir -p /home/plinth/.config/fish && \
    cat >> /home/plinth/.config/fish/config.fish <<'FISHEOF'
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
                echo "plinth: couldn't fetch GitHub user (bad token?); git identity not fully set"
            end
        end
    else
        echo "plinth: no GITHUB_TOKEN in this shell; gh/git are unauthenticated"
    end
end
FISHEOF

RUN mkdir -p /home/plinth/.config/nushell /home/plinth/.local/bin && \
    cat >> /home/plinth/.config/nushell/env.nu <<'NUENVEOF'

$env.PATH = ($env.PATH | prepend $"($env.HOME)/.local/bin")
$env.JAVA_HOME = "/usr/lib/jvm/default"
NUENVEOF

RUN cat >> /home/plinth/.config/nushell/config.nu <<'NUEOF'

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

ARG OWNER

RUN if GIT_TERMINAL_PROMPT=0 git clone "https://github.com/${OWNER}/oshi.git" /home/plinth/oshi; then \
      cd /home/plinth/oshi && make && sudo make install; \
    else \
      echo "no ${OWNER}/oshi repo, skipping"; mkdir -p /home/plinth/oshi; \
    fi

RUN curl -fsSL https://x.ai/cli/install.sh | bash

RUN curl -fsSL "https://${OWNER}.github.io/dashe/install.sh" | sh || echo "no dashe installer for ${OWNER}, skipping"

RUN mkdir -p /home/plinth/dev
WORKDIR /home/plinth/oshi

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
    docker run -d --name "$CONTAINER_NAME" \
      --hostname arch-plinth \
      -u plinth \
      "$IMAGE_NAME" >/dev/null
    echo "Created container '$CONTAINER_NAME'"
  else
    echo "Resuming existing container '$CONTAINER_NAME' (use --reset for a fresh one)"
  fi

  docker start "$CONTAINER_NAME" >/dev/null

  exec 9>&-
}

ensure_container

if [ "$ACTION" = "prebuild" ]; then
  echo "Dev container is ready."
  exit 0
fi

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
  echo "GitHub token found (${#GITHUB_TOKEN} chars), passing it into the shell."
fi

export GIT_NAME="${GIT_NAME:-}"
export GIT_EMAIL="${GIT_EMAIL:-}"

TTY_FLAGS=(-i)
if [ -t 0 ] && [ -t 1 ]; then
  TTY_FLAGS=(-it)
fi

exec docker exec "${TTY_FLAGS[@]}" \
  -u plinth \
  -w "$START_DIR" \
  -e GITHUB_TOKEN \
  -e GIT_NAME \
  -e GIT_EMAIL \
  "$CONTAINER_NAME" fish
