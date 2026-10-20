#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

WORKFLOW="umm.yml"
SSH_USER="runner"
WAIT_RUNNER=600
WAIT_SSH=180

REPO=""
REPO_NAME=""
RUN_ID=""
RUNNER_IP=""

if [[ -t 2 ]]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; RST=$'\e[0m'
else
  BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; RST=""
fi

info() { printf '%s\n' "${BOLD}>${RST} $*" >&2; }
ok()   { printf '%s\n' "${GRN}ok${RST} $*" >&2; }
warn() { printf '%s\n' "${YLW}!${RST} $*" >&2; }
die()  { printf '%s\n' "${RED}error${RST} $*" >&2; exit 1; }

progress()      { if [[ -t 2 ]]; then printf '\r\e[K%s' "${DIM}$1${RST}" >&2; fi; }
progress_done() { if [[ -t 2 ]]; then printf '\r\e[K' >&2; fi; }

(($# == 0)) || die "connect.sh takes no arguments"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=4
)

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found. $2"; }

latest_id() {
  gh run list -R "$REPO" -w "$WORKFLOW" -e workflow_dispatch -L 1 \
    --json databaseId --jq '.[0].databaseId // empty'
}

active_id() {
  gh run list -R "$REPO" -w "$WORKFLOW" -e workflow_dispatch -L 10 \
    --json databaseId,status \
    --jq '[.[] | select(.status != "completed")][0].databaseId // empty'
}

run_status() {
  gh run view "$1" -R "$REPO" --json status,conclusion \
    --jq '.status + "/" + (.conclusion // "")'
}

maybe_stop() {
  [[ -n "$RUN_ID" ]] || return 0
  local ans

  if [[ -t 0 ]]; then
    read -r -p "Stop the runner now? [Y/n] " ans || ans="n"
    if [[ ! "${ans:-y}" =~ ^[Nn] ]]; then
      info "Cancelling run #$RUN_ID"
      if gh run cancel "$RUN_ID" -R "$REPO" >/dev/null 2>&1; then
        ok "Runner stopped"
      else
        warn "Couldn't cancel (maybe it already finished)"
      fi
      return 0
    fi
  fi

  info "Leaving the runner up. Stop it later with: gh run cancel $RUN_ID -R $REPO"
}

on_interrupt() {
  progress_done
  echo >&2
  warn "Interrupted"
  maybe_stop
  exit 130
}

dispatch_run() {
  local before
  before="$(latest_id || true)"

  info "Dispatching $WORKFLOW on $REPO"
  gh workflow run "$WORKFLOW" -R "$REPO" >/dev/null

  SECONDS=0
  while :; do
    RUN_ID="$(latest_id || true)"
    if [[ -n "$RUN_ID" && "$RUN_ID" != "$before" ]]; then
      break
    fi
    (( SECONDS < 60 )) || die "Dispatched, but couldn't find the new run. Check: gh run list -R $REPO -w $WORKFLOW"
    sleep 2
  done
  ok "Run #$RUN_ID started"
}

wait_for_runner() {
  local host="github-runner-$RUN_ID" ip st
  info "Waiting for $host to join the tailnet"

  SECONDS=0
  while :; do
    ip="$(tailscale ip -4 "$host" 2>/dev/null | head -n1 || true)"
    if [[ -n "$ip" ]]; then
      progress_done
      RUNNER_IP="$ip"
      ok "Runner is on the tailnet at $RUNNER_IP"
      return 0
    fi

    st="$(run_status "$RUN_ID" 2>/dev/null || true)"
    if [[ "$st" == completed/* ]]; then
      progress_done
      die "Run #$RUN_ID ended (${st#completed/}) before the runner came up. See: gh run view $RUN_ID -R $REPO --log-failed"
    fi

    if (( SECONDS >= WAIT_RUNNER )); then
      progress_done
      die "Timed out after ${WAIT_RUNNER}s. Check: gh run view $RUN_ID -R $REPO --web"
    fi

    progress "  runner starting... ${SECONDS}s (${st%%/*})"
    sleep 5
  done
}

wait_for_ssh() {
  info "Waiting for SSH on $RUNNER_IP"

  SECONDS=0
  until ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=5 \
        "$SSH_USER@$RUNNER_IP" true 2>/dev/null; do
    if (( SECONDS >= WAIT_SSH )); then
      progress_done
      die "SSH never accepted us. Is the private key for the SSH secret at ~/.ssh/$REPO_NAME, loaded with ssh-add, or your default key?"
    fi
    progress "  waiting for sshd... ${SECONDS}s"
    sleep 3
  done
  progress_done
  ok "SSH is up"
}

need gh        "Install: https://cli.github.com"
need tailscale "Install: https://tailscale.com/download"
need ssh       "Install an OpenSSH client."

gh auth status >/dev/null 2>&1 || die "gh isn't logged in. Run: gh auth login"
tailscale status >/dev/null 2>&1 || die "Tailscale isn't connected on this machine. Start it and sign in."

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
[[ -n "$REPO" ]] || die "Couldn't work out the repo. Run this from inside a clone of it."
REPO_NAME="${REPO#*/}"

SSH_KEY="$HOME/.ssh/$REPO_NAME"
if [[ -f "$SSH_KEY" ]]; then
  SSH_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
fi

RUN_ID="$(active_id || true)"
if [[ -n "$RUN_ID" ]]; then
  info "Reusing active run #$RUN_ID"
fi

trap on_interrupt INT
if [[ -z "$RUN_ID" ]]; then
  dispatch_run
fi

wait_for_runner
wait_for_ssh
trap - INT

GIT_NAME_LOCAL="$(git config --get user.name 2>/dev/null || true)"
GIT_EMAIL_LOCAL="$(git config --get user.email 2>/dev/null || true)"

REMOTE_CMD="GIT_NAME=$(printf '%q' "$GIT_NAME_LOCAL") GIT_EMAIL=$(printf '%q' "$GIT_EMAIL_LOCAL") exec bash ~/$(printf '%q' "$REPO_NAME")/container/doc.sh"

info "Connecting and entering the dev container"
set +e
ssh -t "${SSH_OPTS[@]}" "$SSH_USER@$RUNNER_IP" "$REMOTE_CMD"
rc=$?
set -e

echo >&2
maybe_stop
exit "$rc"
