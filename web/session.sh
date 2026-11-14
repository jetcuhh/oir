#!/usr/bin/env bash
# What the web terminal runs. Three layers, each one `exit` further out:
#
#   container (fish)  ->  runner shell (ubuntu)  ->  "stop the workflow?" prompt
#
# Run from anywhere; it finds the repo root itself.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DIM=$'\e[2m'; BOLD=$'\e[1m'; RED=$'\e[38;2;227;123;102m'; RST=$'\e[0m'

stop_workflow() {
  if [[ -z "${OIR_CANCEL_TOKEN:-}" || -z "${GITHUB_RUN_ID:-}" ]]; then
    printf '%s\n' "${RED}can't stop it from here${RST} (no token or run id). Use ./connect.sh stop on your machine."
    return 1
  fi
  printf '%s\n' "${DIM}stopping run #${GITHUB_RUN_ID}...${RST}"
  GH_TOKEN="$OIR_CANCEL_TOKEN" gh run cancel "$GITHUB_RUN_ID" -R "$GITHUB_REPOSITORY" >/dev/null 2>&1 \
    || { printf '%s\n' "${RED}cancel failed${RST}"; return 1; }
  # The runner goes down within a few seconds; wait so the prompt doesn't flicker back.
  sleep 60
}

# Claude connector URL (add it once as a custom connector in Claude web).
if [[ -r "$HOME/mcp.token" && -r "$HOME/link/url.txt" ]]; then
  printf '%s\n' "${DIM}mcp connector: $(head -n1 "$HOME/link/url.txt")/mcp/$(cat "$HOME/mcp.token")${RST}"
fi

# Layer 1: the container. doc.sh builds/starts it on demand and attaches.
bash container/doc.sh

# Layer 2: the runner itself.
RC="$(mktemp)"
trap 'rm -f "$RC"' EXIT
{
  printf '%s\n' "alias oir='bash $ROOT/container/doc.sh'"
  cat <<'EOF'
export PS1='\[\e[2m\]runner\[\e[0m\] \[\e[38;2;227;123;102m\]\$\[\e[0m\] '
# the web terminal names the tab after the directory
PROMPT_COMMAND='if [ "$PWD" = "$HOME" ]; then t="~"; else t="${PWD##*/}"; fi; printf "\033]0;%s\007" "$t"'
alias ll='ls -lah --color=auto'
alias ls='ls --color=auto'
EOF
} > "$RC"

printf '\n%s\n' "${DIM}left the container. you are on the runner now.${RST}"
printf '%s\n\n' "${DIM}${BOLD}oir${RST}${DIM} goes back in, ${BOLD}exit${RST}${DIM} stops the workflow.${RST}"

while :; do
  bash --noprofile --rcfile "$RC" -i
  echo
  # Layer 3: leaving the runner shell asks before taking the runner down.
  read -r -p "${BOLD}Stop the workflow?${RST} [y/N] " ans || ans="y"
  if [[ "${ans:-n}" =~ ^[Yy] ]]; then
    stop_workflow || continue
    exit 0
  fi
done
