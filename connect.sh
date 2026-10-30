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

progress() {
  if [[ -t 2 ]]; then printf '\r\e[K%s' "${DIM}$1${RST}" >&2; fi
}
progress_done() { if [[ -t 2 ]]; then printf '\r\e[K' >&2; fi }

usage() {
  cat <<'USAGE'
connect.sh - connect to the Oir runner.

  ./connect.sh               start a runner, or join one that's already running
  ./connect.sh stop          pick a running runner and stop it
  ./connect.sh push <path>   copy a file/dir into the container's ~/dev
  ./connect.sh pull <name>   copy ~/dev/<name> from the container back here
USAGE
}

ACTION=connect
TRANSFER=""
case "${1:-}" in
  "")
    ;;
  stop)
    ACTION=stop
    ;;
  push|pull)
    ACTION=$1
    shift
    (($# >= 1)) || die "Usage: ./connect.sh $ACTION <file-or-dir>"
    TRANSFER="$1"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    die "Unknown command: $1 (try --help)"
    ;;
esac
(($# <= 1)) || die "Too many arguments (try --help)"

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

load_active_runs() {
  IDS=(); STARTS=(); STATS=(); BRANCHES=()
  local id status started branch
  while IFS=$'\t' read -r id status started branch; do
    [[ -n "$id" ]] || continue
    IDS+=("$id")
    STATS+=("$status")
    STARTS+=("$started")
    BRANCHES+=("$branch")
  done < <(gh run list -R "$REPO" -w "$WORKFLOW" -e workflow_dispatch -L 20 \
             --json databaseId,status,startedAt,createdAt,headBranch \
             --jq '[.[] | select(.status != "completed")]
                   | sort_by(if .status == "in_progress" then 0 elif .status == "queued" then 1 else 2 end)
                   | .[] | [.databaseId, .status, (.startedAt // .createdAt), (.headBranch // "-")] | @tsv')
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

elapsed_secs() {
  local start=$1 secs
  secs=$(date -d "$start" +%s 2>/dev/null) || { printf '0'; return; }
  secs=$(( $(date +%s) - secs ))
  (( secs >= 0 )) || secs=0
  printf '%s' "$secs"
}

fmt_dur() {
  local s=$1 h m
  if (( s >= 3600 )); then
    h=$(( s / 3600 ))
    m=$(( (s % 3600) / 60 ))
    if (( m > 0 )); then printf '%dh%dm' "$h" "$m"; else printf '%dh' "$h"; fi
  elif (( s >= 60 )); then
    printf '%dm' $(( s / 60 ))
  else
    printf '%ds' "$s"
  fi
}

read_key() {
  local k rest
  IFS= read -rsn1 k || return 1
  if [[ "$k" == $'\e' ]]; then
    IFS= read -rsn2 -t 0.05 rest || true
    case "$rest" in
      '[A'|'OA') printf 'up' ;;
      '[B'|'OB') printf 'down' ;;
      *) printf 'other' ;;
    esac
  elif [[ -z "$k" || "$k" == $'\n' ]]; then
    printf 'enter'
  else
    printf '%s' "$k"
  fi
}

run_menu() {
  local header=$1 allow_new=$2 start=${3:-0}
  local extra=0 n i line key j
  (( allow_new )) && extra=1
  n=$(( ${#IDS[@]} + extra ))
  PICKED=$start
  DRAWN=0

  render() {
    if (( DRAWN > 0 )); then printf '\e[%dA' "$DRAWN" >&2; fi
    for (( i = 0; i < n; i++ )); do
      if (( extra == 1 && i == 0 )); then
        line="+ dispatch a new runner"
      else
        j=$(( i - extra ))
        line="$(printf 'run %s  %-6s %-11s %s  github-runner-%s' \
                  "${IDS[j]}" "$(fmt_dur "$(elapsed_secs "${STARTS[j]}")")" \
                  "${STATS[j]}" "${BRANCHES[j]}" "${IDS[j]}")"
      fi
      if (( i == PICKED )); then
        printf '\r\e[K%s %s\n' "${GRN}>${RST}" "${BOLD}${line}${RST}" >&2
      else
        printf '\r\e[K  %s\n' "$line" >&2
      fi
    done
    DRAWN=$n
  }

  printf '%s\n' "$header" >&2
  render

  while :; do
    key="$(read_key)" || { echo >&2; return 1; }
    case "$key" in
      up|k) if (( PICKED > 0 )); then PICKED=$(( PICKED - 1 )); fi ;;
      down|j) if (( PICKED < n - 1 )); then PICKED=$(( PICKED + 1 )); fi ;;
      q|Q) return 1 ;;
      enter) return 0 ;;
      *) continue ;;
    esac
    render
  done
}

cmd_stop() {
  [[ -t 0 ]] || die "'stop' needs an interactive terminal"

  load_active_runs
  if (( ${#IDS[@]} == 0 )); then
    info "No running runners."
    return 0
  fi

  run_menu "Running runners (up/down to move, enter to stop, q to quit):" 0 || return 0

  local id="${IDS[PICKED]}"
  info "Cancelling run #$id (github-runner-$id)"
  if gh run cancel "$id" -R "$REPO" >/dev/null 2>&1; then
    ok "Runner stopped"
  else
    warn "Couldn't cancel run #$id (maybe it already finished)"
    return 1
  fi
}

cmd_share() {
  load_active_runs
  if (( ${#IDS[@]} == 0 )); then
    die "No running runner. Start one with ./connect.sh"
  fi

  if (( ${#IDS[@]} == 1 )); then
    RUN_ID="${IDS[0]}"
  else
    run_menu "Running runners (up/down to move, enter to select, q to quit):" 0 0 || exit 0
    RUN_ID="${IDS[PICKED]}"
  fi

  RUNNER_IP="$(tailscale ip -4 "github-runner-$RUN_ID" 2>/dev/null | head -n1 || true)"
  [[ -n "$RUNNER_IP" ]] || die "github-runner-$RUN_ID isn't on the tailnet (yet)"

  ssh "${SSH_OPTS[@]}" "$SSH_USER@$RUNNER_IP" 'mkdir -p ~/dev'

  if [[ "$ACTION" == push ]]; then
    info "Pushing $TRANSFER to github-runner-$RUN_ID:~/dev"
    scp -r "${SSH_OPTS[@]}" "$TRANSFER" "$SSH_USER@$RUNNER_IP:dev/"
    ok "In the container at ~/dev/$(basename "$TRANSFER")"
  else
    info "Pulling github-runner-$RUN_ID:~/dev/$TRANSFER"
    scp -r "${SSH_OPTS[@]}" "$SSH_USER@$RUNNER_IP:dev/$TRANSFER" .
    ok "Pulled $TRANSFER"
  fi
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

    progress "  github-runner-$RUN_ID: ${st:-unknown} (${SECONDS}s)"
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
    progress "  sshd not answering on $RUNNER_IP (${SECONDS}s)"
    sleep 3
  done
  progress_done
  ok "SSH is up"
}

need gh "Install: https://cli.github.com"
gh auth status --active >/dev/null 2>&1 || die "gh isn't logged in. Run: gh auth login"

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
[[ -n "$REPO" ]] || die "Couldn't work out the repo. Run this from inside a clone of it."
REPO_NAME="${REPO#*/}"

if [[ "$ACTION" == stop ]]; then
  cmd_stop
  exit
fi

need tailscale "Install: https://tailscale.com/download"
need ssh       "Install an OpenSSH client."

tailscale status >/dev/null 2>&1 || die "Tailscale isn't connected on this machine. Start it and sign in."

SSH_KEY="$HOME/.ssh/$REPO_NAME"
if [[ -f "$SSH_KEY" ]]; then
  SSH_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
fi

if [[ "$ACTION" == push || "$ACTION" == pull ]]; then
  cmd_share
  exit
fi

load_active_runs
if (( ${#IDS[@]} > 0 )); then
  if [[ -t 0 ]]; then
    run_menu "${#IDS[@]} active run(s) (up/down to move, enter to select, q to quit):" 1 1 || exit 0
    if (( PICKED == 0 )); then
      dispatch_run
    else
      RUN_ID="${IDS[PICKED-1]}"
      info "Joining run #$RUN_ID"
    fi
  else
    RUN_ID="${IDS[0]}"
    info "Reusing active run #$RUN_ID"
  fi
else
  dispatch_run
fi

trap on_interrupt INT

wait_for_runner
wait_for_ssh
trap - INT

GIT_NAME_LOCAL="$(git config --get user.name 2>/dev/null || true)"
GIT_EMAIL_LOCAL="$(git config --get user.email 2>/dev/null || true)"
LAPTOP_HOST="$(tailscale status --peers=false --json 2>/dev/null | sed -n 's/.*"DNSName":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 | sed 's/\.$//')"
LAPTOP_USER="$(id -un)"

REMOTE_CMD="GIT_NAME=$(printf '%q' "$GIT_NAME_LOCAL") GIT_EMAIL=$(printf '%q' "$GIT_EMAIL_LOCAL") LAPTOP_HOST=$(printf '%q' "$LAPTOP_HOST") LAPTOP_USER=$(printf '%q' "$LAPTOP_USER") exec bash ~/$(printf '%q' "$REPO_NAME")/container/doc.sh"

info "Connecting and entering the Oir container"
set +e
ssh -t "${SSH_OPTS[@]}" "$SSH_USER@$RUNNER_IP" "$REMOTE_CMD"
rc=$?
set -e

echo >&2
maybe_stop
exit "$rc"
