#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${OIR_REPO:-jetdafih/oir}"
WORKFLOW="um.yml"
WAIT_LINK=1200   # give up after this many seconds
GH_POLL=3        # seconds between looks at the run on GitHub
LIMIT=21600      # the workflow's 6h limit, for "time left"

RUN_ID=""
LINK_URL=""
JOINED=false
LIVE=0           # is the live block drawn on screen?
DONE_LINES=0     # finished-phase lines printed above it

if [[ -t 2 ]]; then
  DIM=$'\e[2m'; BOLD=$'\e[1m'; ACC=$'\e[38;2;227;123;102m'; RST=$'\e[0m'
  COLS="$(tput cols 2>/dev/null || echo 80)"
else
  DIM=""; BOLD=""; ACC=""; RST=""; COLS=80
fi

say()  { printf '%s\n' "$*" >&2; }
die()  { live_clear; say "x $*"; exit 1; }
warn() { say "${DIM}! $*${RST}"; }

hide_cursor() { [[ -t 2 ]] && printf '\e[?25l' >&2 || true; }
show_cursor() { [[ -t 2 ]] && printf '\e[?25h' >&2 || true; }
# Whatever happens, hand the cursor back to the shell.
trap show_cursor EXIT

fmt_time() {
  if (( $1 < 60 )); then printf '%ds' "$1"; else printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); fi
}
fmt_span() {
  if (( $1 >= 3600 )); then printf '%dh %02dm' $(( $1 / 3600 )) $(( $1 % 3600 / 60 ));
  elif (( $1 >= 60 )); then printf '%dm' $(( $1 / 60 ));
  else printf '%ds' "$1"; fi
}
trunc() {
  local s="$1" max="$2"
  if (( ${#s} > max )); then s="${s:0:$(( max - 1 ))}…"; fi
  printf '%s' "$s"
}

usage() {
  cat <<'USAGE'
connect.sh - open a shell on the Oir runner, in your browser.

  ./connect.sh          start a runner, wait until its container is built, then print
                        the link to its web terminal. If a runner is already up you
                        get a menu: reuse it, or start another one
  ./connect.sh --open   same, and open the link in your browser
  ./connect.sh stop     stop a runner (a menu when more than one is up)

Needs: gh (logged in). Log in on the page with the OIR_PASSWORD repo secret.
The link is a Cloudflare quick tunnel: it changes every run, 6h at most.
Set OIR_REPO=owner/name to use another repo.
USAGE
}

ACTION=connect
OPEN=false
for arg in "$@"; do
  case "$arg" in
    stop) ACTION=stop ;;
    -o|--open) OPEN=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found. $2"; }

# Active (queued or running) runs: "<id>\t<status>\t<age in seconds>", running ones first.
active_info() {
  gh run list -R "$REPO" -w "$WORKFLOW" -e workflow_dispatch -L 30 \
    --json databaseId,status,createdAt \
    --jq '[.[] | select(.status != "completed")]
          | sort_by(if .status == "in_progress" then 0 else 1 end)
          | .[] | "\(.databaseId)\t\(.status)\t\((now - (.createdAt | fromdateiso8601)) | floor)"'
}

latest_id() {
  gh run list -R "$REPO" -w "$WORKFLOW" -e workflow_dispatch -L 1 \
    --json databaseId --jq '.[0].databaseId // empty'
}

# One call: "<status>\t<conclusion or ->\t<name of the step that is running now>"
# (the "-" keeps tab-splitting from collapsing an empty middle field)
run_state() {
  gh run view "$1" -R "$REPO" --json status,conclusion,jobs \
    --jq '.status + "\t" + (.conclusion // "-") + "\t"
          + ((.jobs[0].steps // []) | map(select(.status == "in_progress")) | .[0].name // "")'
}

failed_step() {
  gh run view "$1" -R "$REPO" --json jobs \
    --jq '[.jobs[].steps[]? | select(.conclusion == "failure")][0].name // empty' 2>/dev/null || true
}

cancel_run() { gh run cancel "$1" -R "$REPO" >/dev/null 2>&1; }

# ---- menus ---------------------------------------------------------------------------

# pick TITLE ITEM...   up/down (or j/k), 1-9, enter to choose, q or esc to cancel.
# Sets PICK (0-based, -1 = cancelled); returns 1 when there is no terminal to ask on.
PICK=-1
pick() {
  local title="$1"; shift
  local items=("$@") n=$# sel=0 i key rest
  PICK=-1
  [[ -t 0 && -t 2 ]] || return 1
  say "$title"
  hide_cursor
  while :; do
    for (( i = 0; i < n; i++ )); do
      if (( i == sel )); then
        printf '\r\e[2K  %s❯%s %s%s%s\n' "$ACC" "$RST" "$BOLD" "${items[i]}" "$RST" >&2
      else
        printf '\r\e[2K    %s%s%s\n' "$DIM" "${items[i]}" "$RST" >&2
      fi
    done
    IFS= read -rsn1 key || key=q
    case "$key" in
      $'\e')
        rest=""; read -rsn2 -t 1 rest || true
        case "$rest" in
          '[A') sel=$(( (sel + n - 1) % n )) ;;
          '[B') sel=$(( (sel + 1) % n )) ;;
          '')   PICK=-1; break ;;
        esac ;;
      k) sel=$(( (sel + n - 1) % n )) ;;
      j) sel=$(( (sel + 1) % n )) ;;
      '') PICK=$sel; break ;;
      q)  PICK=-1; break ;;
      [1-9]) if (( key <= n )); then PICK=$(( key - 1 )); break; fi ;;
    esac
    printf '\e[%dA' "$n" >&2
  done
  printf '\e[%dA\e[J' $(( n + 1 )) >&2     # erase the menu again
  return 0
}

RUN_IDS=(); RUN_ST=(); RUN_AGE=()
load_runs() {
  local id st age
  RUN_IDS=(); RUN_ST=(); RUN_AGE=()
  while IFS=$'\t' read -r id st age; do
    [[ -n "$id" ]] || continue
    RUN_IDS+=("$id"); RUN_ST+=("$st"); RUN_AGE+=("$age")
  done < <(active_info 2>/dev/null || true)
}

describe_run() {
  local i="$1" age left
  age="${RUN_AGE[$i]}"
  left=$(( LIMIT - age )); (( left > 0 )) || left=0
  if [[ "${RUN_ST[$i]}" == in_progress ]]; then
    printf '#%s  running · up %s · %s left' "${RUN_IDS[$i]}" "$(fmt_span "$age")" "$(fmt_span "$left")"
  else
    printf '#%s  queued · waiting %s' "${RUN_IDS[$i]}" "$(fmt_span "$age")"
  fi
}

cmd_stop() {
  local n i id ok=0 items=() targets=()
  load_runs
  n=${#RUN_IDS[@]}
  if (( n == 0 )); then
    say "${DIM}nothing running${RST}"
    return 0
  fi

  if (( n == 1 )); then
    targets=("${RUN_IDS[0]}")
  else
    for (( i = 0; i < n; i++ )); do items+=("stop  $(describe_run "$i")"); done
    items+=("stop  all $n")
    items+=("cancel")
    if pick "Stop which runner?" "${items[@]}"; then
      if (( PICK < 0 || PICK == n + 1 )); then say "${DIM}nothing stopped${RST}"; return 0; fi
      if (( PICK == n )); then targets=("${RUN_IDS[@]}"); else targets=("${RUN_IDS[$PICK]}"); fi
    else
      targets=("${RUN_IDS[@]}")        # no terminal to ask on: stop them all
    fi
  fi

  for id in "${targets[@]}"; do
    if cancel_run "$id"; then
      say "stopped run #$id"
      ok=$(( ok + 1 ))
    else
      warn "couldn't stop run #$id (already finished?)"
    fi
  done
  (( ok == ${#targets[@]} ))
}

dispatch_run() {
  local before
  before="$(latest_id || true)"
  gh workflow run "$WORKFLOW" -R "$REPO" >/dev/null

  SECONDS=0
  while :; do
    RUN_ID="$(latest_id || true)"
    [[ -n "$RUN_ID" && "$RUN_ID" != "$before" ]] && break
    (( SECONDS < 60 )) || die "dispatched, but the new run didn't show up. Check: gh run list -R $REPO -w $WORKFLOW"
    sleep 2
  done
}

# A runner may already be up: offer to reuse it or start another one.
choose_run() {
  local n i items=()
  load_runs
  n=${#RUN_IDS[@]}
  if (( n == 0 )); then
    dispatch_run
    return
  fi

  JOINED=true
  RUN_ID="${RUN_IDS[0]}"               # no terminal to ask on: reuse the first one
  for (( i = 0; i < n; i++ )); do items+=("reuse  $(describe_run "$i")"); done
  items+=("new    start another runner")
  if pick "$( (( n == 1 )) && echo 'A runner is already up.' || echo "$n runners are already up.")" "${items[@]}"; then
    if (( PICK < 0 )); then exit 130; fi
    if (( PICK == n )); then
      JOINED=false
      dispatch_run
    else
      RUN_ID="${RUN_IDS[$PICK]}"
    fi
  fi
}

# ---- live progress -------------------------------------------------------------------

# A three-line block that is redrawn in place; finished phases are printed above it.
live_draw() {
  [[ -t 2 ]] || return 0
  hide_cursor
  printf '\r\e[2K%s\n\e[2K%s\n\e[2K%s\e[2A\r' "$1" "$2" "$3" >&2
  LIVE=1
}
live_clear() {
  [[ "$LIVE" == 1 ]] || return 0
  printf '\r\e[2K\n\e[2K\n\e[2K\e[2A\r' >&2
  LIVE=0
}

PHASE_LABELS=("waiting for a runner" "starting the runner" "opening the tunnel" "building the container")

# Which phase a step of the workflow belongs to (keep in sync with um.yml).
phase_of() {
  case "$1" in
    "Record start time"|"Check secrets"|"Clone repo"|"Store GitHub token"*) echo 1 ;;
    "Pre-build dev container"*|"Fetch JetBrainsMono"*|"Start web terminal"*|"Open a Cloudflare"*|"Publish the link"*) echo 2 ;;
    "Wait for the container") echo 3 ;;
    "Keep runner alive"*|"Diagnostics"*|"Upload logs") echo 4 ;;
    *) echo "" ;;
  esac
}

phase_done() {   # $1 phase, $2 seconds it took (empty when unknown)
  local t=""
  live_clear
  [[ -n "$2" ]] && t="  ${DIM}$(fmt_time "$2")${RST}"
  say "  ${PHASE_LABELS[$1]}${t}"
  DONE_LINES=$(( DONE_LINES + 1 ))
}

bar() {   # bar DONE TOTAL
  local i="$1" n="$2" w=10 f k out=""
  (( n > 0 )) || return 0
  f=$(( i * w / n ))
  for (( k = 0; k < w; k++ )); do
    if (( k < f )); then out+="▰"; else out+="▱"; fi
  done
  printf '%s' "$out"
}

on_interrupt() {
  live_clear
  show_cursor
  say
  if [[ -n "$RUN_ID" && -t 0 ]]; then
    local ans
    read -r -p "Stop the runner now? [y/N] " ans || ans="n"
    if [[ "${ans:-n}" =~ ^[Yy] ]]; then
      cancel_run "$RUN_ID" && say "stopped" || warn "couldn't cancel (already finished?)"
      exit 130
    fi
  fi
  [[ -z "$RUN_ID" ]] || say "${DIM}runner left up: ./connect.sh to get the link, ./connect.sh stop to end it${RST}"
  exit 130
}

# Explain a failed run in one or two lines.
report_failure() {
  local conclusion="$1" step
  step="$(failed_step "$RUN_ID")"
  live_clear
  say "x run #$RUN_ID ${conclusion:-ended}${step:+ at ${BOLD}$step${RST}}"
  case "$step" in
    "Check secrets") say "  ${DIM}set it with: gh secret set OIR_PASSWORD -R $REPO${RST}" ;;
    *)               say "  ${DIM}gh run view $RUN_ID -R $REPO --log-failed${RST}" ;;
  esac
  exit 1
}

# How far the container build is, straight from the runner (see /api/status in server.py).
poll_status() {
  local out k v
  command -v curl >/dev/null 2>&1 || return 0
  out="$(curl -fsS -m 4 "$LINK_URL/api/status" 2>/dev/null)" || return 0
  st_state=""; st_step=""; st_of=""; st_label=""; st_line=""
  while IFS='=' read -r k v; do
    case "$k" in
      state) st_state="$v" ;;
      step)  st_step="$v" ;;
      of)    st_of="$v" ;;
      label) st_label="$v" ;;
      line)  st_line="$v" ;;
    esac
  done <<<"$out"
}

# The workflow publishes the tunnel address as an artifact, which can be downloaded while the
# run is still going. This follows the run phase by phase and returns once the container is
# built. Sets LINK_URL.
wait_for_link() {
  local name="oir-link-$RUN_ID" tmp state status conclusion step p
  local cur=-1 phase_start=0 time_ok=true was_ok first=true finish=false
  local last_gh=-99 last_st=-99 spin=0
  local st_state="" st_step="" st_of="" st_label="" st_line=""
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  local plabel l1 l2 l3 w=$(( COLS - 8 ))
  tmp="$(mktemp -d)"

  SECONDS=0
  while :; do
    if (( SECONDS - last_gh >= GH_POLL )); then
      last_gh=$SECONDS
      state="$(run_state "$RUN_ID" 2>/dev/null || true)"
      status=""; conclusion=""; step=""
      IFS=$'\t' read -r status conclusion step <<<"$state" || true

      if [[ "$status" == completed ]]; then
        rm -rf "$tmp"
        report_failure "${conclusion#-}"
      fi

      case "$status" in
        queued|waiting|pending) p=0 ;;
        in_progress)
          p="$(phase_of "$step")"
          [[ -n "$p" ]] || p=$(( cur < 1 ? 1 : cur )) ;;
        *) p=$(( cur < 0 ? 0 : cur )) ;;   # no answer from GitHub: keep what we had
      esac

      if (( p != cur )); then
        was_ok=$time_ok
        if (( cur >= 0 )); then
          if [[ "$was_ok" == true ]]; then phase_done "$cur" "$(( SECONDS - phase_start ))"; else phase_done "$cur" ""; fi
        fi
        cur=$p
        phase_start=$SECONDS
        time_ok=true
        # joined a run that was already going: we don't know when this phase began
        if [[ "$first" == true && "$JOINED" == true ]]; then time_ok=false; fi
        first=false
      fi

      if [[ -z "$LINK_URL" ]] && (( cur >= 1 )) \
         && gh run download "$RUN_ID" -R "$REPO" -n "$name" -D "$tmp" >/dev/null 2>&1 \
         && [[ -s "$tmp/url.txt" ]]; then
        LINK_URL="$(head -n1 "$tmp/url.txt" | tr -d '\r\n')"
      fi
      # The link is only published once the tunnel is up, so having it means phase 3 at least,
      # even when GitHub returns no step names.
      if [[ -n "$LINK_URL" ]] && (( cur < 3 )); then cur=3; fi
      if (( cur >= 4 )) && [[ -n "$LINK_URL" ]]; then finish=true; fi
    fi

    if [[ -n "$LINK_URL" ]] && (( cur == 3 )) && (( SECONDS - last_st >= 2 )); then
      last_st=$SECONDS
      poll_status
      [[ "$st_state" == ready ]] && finish=true
    fi

    if [[ "$finish" == true ]]; then
      rm -rf "$tmp"
      live_clear
      if [[ -t 2 ]] && (( DONE_LINES > 0 )); then printf '\e[%dA\e[J' "$DONE_LINES" >&2; fi
      return 0
    fi

    if (( SECONDS >= WAIT_LINK )); then
      rm -rf "$tmp"
      die "gave up after $(fmt_time "$SECONDS"). gh run view $RUN_ID -R $REPO --web"
    fi

    # --- what to show ---
    l2=""; l3=""
    case "$cur" in
      0) l2="queued on GitHub, waiting for a free runner" ;;
      1|2) l2="${step}" ;;
      3)
        case "$st_state" in
          building)
            l2="${st_label:-building the image}"
            [[ -n "$st_of" ]] && l2="$l2   $(bar "${st_step:-0}" "$st_of") ${st_step:-0}/$st_of"
            l3="$st_line" ;;
          starting) l2="starting the container" ;;
          *)        l2="waiting for the container to finish building" ;;
        esac ;;
    esac
    if (( cur < 0 )); then plabel="contacting github"; else plabel="${PHASE_LABELS[$cur]}"; fi
    l1="  ${ACC}${frames[spin % ${#frames[@]}]}${RST} ${plabel}  ${DIM}$(fmt_time "$SECONDS")${RST}"
    live_draw "$l1" "    ${DIM}$(trunc "$l2" "$w")${RST}" "    ${DIM}$(trunc "$l3" "$w")${RST}"
    spin=$(( spin + 1 ))
    sleep 0.08
  done
}

open_link() {
  local opener
  for opener in open xdg-open wslview; do
    if command -v "$opener" >/dev/null 2>&1; then
      "$opener" "$LINK_URL" >/dev/null 2>&1 || true
      return 0
    fi
  done
  warn "no browser opener found; open the link yourself"
}

need gh "Install: https://cli.github.com"
gh auth status --active >/dev/null 2>&1 || die "gh isn't logged in. Run: gh auth login"

if [[ "$ACTION" == stop ]]; then
  cmd_stop
  exit
fi

# gh draws its own progress spinner and puts the cursor back when it finishes; re-hide it
# after every call so the block cursor never flashes next to our own progress.
gh() { command gh "$@"; local rc=$?; hide_cursor; return $rc; }
hide_cursor
say "${BOLD}oir${RST} ${DIM}$REPO${RST}"

choose_run

trap on_interrupt INT
wait_for_link
took="$(fmt_time "$SECONDS")"
trap - INT

reused=""
[[ "$JOINED" == true ]] && reused="reused · "
say "ready ${DIM}${reused}run #$RUN_ID · ${took}${RST}"
say
say "  ${ACC}${BOLD}${LINK_URL}${RST}"
say "  ${DIM}run${RST}  https://github.com/$REPO/actions/runs/$RUN_ID"

if [[ "$OPEN" == true ]]; then
  open_link
fi
