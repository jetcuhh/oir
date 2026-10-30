# display.md — remote display runbook

**Reference material, not required reading.** This is not part of the default
onboarding; the user points an agent here when display work is in scope. If you're
reading it, it's because something about the GUI, VNC, or the remote desktop is
on the table right now.

It records the rules that keep the user's work alive, the commands that actually
work here, the measurements that decide which "fixes" are real, and how to talk to
the user about them.

---

## 0. Mental model

There are three machines, and confusing them is the #1 source of wasted time.

```
laptop  ──Tailscale (DERP relay, ~267 ms RTT)──  runner host  ──docker bridge──  container
        wlvncc 127.0.0.1                         sshd           $CIP              sway + wayvnc
```

- **SSH lands on the runner host**, not in the container. `localhost` in an SSH
  command is the *host*, not the container.
- The GUI lives in the **container `jetbrainsmono`** (`172.17.0.2` right now —
  resolve it every run, see §2.1).
- Inside the container: `XDG_RUNTIME_DIR=/tmp/xdg-1000`, `WAYLAND_DISPLAY=wayland-1`,
  output `HEADLESS-1`, RFB on `0.0.0.0:5900`.
- `sway` runs on the **wlroots headless backend** with `WLR_RENDERER=pixman`;
  there is no `/dev/dri`, no GPU, no X11, no Xwayland. Software GL only (llvmpipe).
- The user's laptop reaches the display through an SSH local forward to the
  container IP, then a VNC client.

Stack: sway 1.12, wayvnc 0.10.2, neatvnc 1.0.3, Chromium 154, grim 1.5.0,
Arch, 4 vCPU EPYC 7763, 15 GB RAM, Mesa 25.2.5 llvmpipe.

### Why sway and not niri

Because **niri has no headless backend**. Verified against niri 26.04 in this
container, not from memory:

- `niri --help` exposes no `--headless`/virtual-output option; the binary only
  contains the `udev` and `winit` (nested) backends.
- Running it standalone with no `/dev/dri` panics immediately:
  ```
  error initializing the TTY backend
  0: Error creating a session...
  1: Failed to open session: Function not implemented (os error 38)
  ```
  It needs a DRM device or a TTY seat. Neither exists in this container.
- The important part: niri *does* advertise `zwlr_screencopy_manager_v1`,
  `zwlr_virtual_pointer_manager_v1` and `zwp_virtual_keyboard_manager_v1`, so
  wayvnc would capture it and inject input fine **if it had an output**.

The only ways to give niri an output here are (a) run it nested inside sway's
winit backend — a compositor inside a compositor, doubling llvmpipe work on an
already saturated box, so strictly worse; or (b) pass through a virtual DRM
device (`vkms`, `virtio-gpu`), which a GitHub-hosted runner does not have and
which would need host kernel access. So: **sway stays.** wlroots ships the
headless backend; that is the whole reason it was chosen.

---

## 1. Hard rules

Violating any of these loses the user's data, breaks the display, or wastes an
hour of the user's time.

1. **Never run `doc.sh --reset` or `--rebuild`.** The container holds
   `/home/jetbrain/dev` (the user's projects: `echo`, `echo-linux-port`). `--reset`
   deletes it with no recovery. If something is broken, fix the process, not the
   container.
2. **No X11, ever.** Do not install `tigervnc-server`, `x11vnc`, `xvfb`,
   `xorg-server`, or start Chromium with `--ozone-platform=x11`. The user asked
   explicitly for a X11-free stack. If a tool needs X, it is the wrong tool.
3. **Chromium needs `--no-sandbox`.** The container blocks `CLONE_NEWPID` /
   `CLONE_NEWNET`, so the sandbox cannot start. The "unsupported flag" infobar is
   expected and not a bug to fix.
4. **Tunnels target the container IP, not `127.0.0.1`.** It is `172.17.0.2` in
   the current container, but resolve it with `docker inspect` every time — it
   changes when the container is recreated. `ssh -L 5900:127.0.0.1:5900` gives
   you the *host's* view, where nothing is listening.
5. **`vncviewer 127.0.0.1`, never `vncviewer 127.0.0.1:5900`.** TigerVNC parses
   `:5900` as *display* 5900 (port 11800). For a non-default port the form is
   `host::port`.
6. **Never `pkill -f <pattern>` where the pattern can match your own command
   line.** `pkill -f 'net.minecraft'` kills the shell running it, because the
   shell's own `bash -c` string contains that text. Use `pkill -x <comm>`.
7. **Filter zombies when checking liveness.** PID 1 is `sleep infinity`, so
   orphans are never reaped. This box currently carries ~550 zombies, including
   439 `gpg <defunct>`. `pgrep` matches them; parse `ps -eo stat=,comm=` and skip
   anything starting with `Z`.
8. **Don't restart `sway` to restart `wayvnc`.** Killing sway kills every app in
   the session (including a running game). Restart the single process instead.
9. **Set the session env for every `docker exec`.** `XDG_RUNTIME_DIR` and
   `WAYLAND_DISPLAY` are not inherited; tools like `grim`, `swaymsg`, `wayvnc`
   used to fail with "failed to connect to display" until both are exported.

---

## 2. Entry points

`connect.sh` does **one** job: get you a shell in the dev container (dispatch or
reuse a runner, wait for Tailscale + sshd, attach). Display access is separate and
manual — the user does not use the `vnc` action, so don't assume a tunnel exists
just because they're SSHed in.

| Command | Effect |
|---|---|
| `./connect.sh` | Start/reuse a runner, SSH into the dev container |
| `./connect.sh stop` | Pick a running run and cancel it |

(`./connect.sh` has **no** display action — it only gets you a shell. Tunnelling
and the client are manual, §2.3. Don't go looking for a `vnc` subcommand.)

### 2.1 Resolve the addresses — never hardcode them

Every IP is different per run. Do not paste a `100.x.y.z` or `172.17.0.x` from an
old log, from this document, or from the user's previous session.

```bash
KEY="$HOME/.ssh/oir"        # connect.sh defaults to ~/.ssh/<repo-name>
SSH="ssh -i $KEY -o IdentitiesOnly=yes \
         -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# runner: the online tailnet peer named github-runner-<run_id>
RUNNER_IP=$(tailscale status --json \
  | jq -r '[.Peer[] | select(.HostName|startswith("github-runner-")) | select(.Online) | .TailscaleIPs[0]][0] // empty')
echo "runner: $RUNNER_IP"

# container: only the runner host owns docker, so ask it
CIP=$($SSH runner@"$RUNNER_IP" \
        "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' jetbrainsmono")
echo "container: $CIP"
```

No `jq`? `tailscale status | awk '/github-runner/ {print $1; exit}'` is the crude
equivalent. Confirm the peer is actually the one you want with
`tailscale status | grep github-runner` before tunnelling.

`docker inspect` returning nothing means the container doesn't exist yet — run
`./connect.sh` once, which is also what creates it.

### 2.2 Client

`wlvncc` is the client in use — Wayland-native, no Qt, no X11:

- AUR: <https://aur.archlinux.org/packages/wlvncc-git>
- upstream: <https://github.com/any1/wlvncc>
- version built for this setup: `wlvncc-git r150.cc0abf8-1`

```bash
paru -S wlvncc-git      # or: yay -S wlvncc-git
```

Address and port are **separate arguments** — there is no TigerVNC `:display`
syntax:

```
Usage: wlvncc <address> [port]
```

Its flags matter for tuning, so keep them handy:

| Flag | Meaning |
|---|---|
| `-e, --encodings=<list>` | `tight, zrle, ultra, copyrect, hextile, zlib, corre, rre, raw, open-h264` |
| `-c, --compression=<0-9>` | Compression level |
| `-q, --quality=<0-9>` | Image quality |
| `-n, --hide-cursor` | Hide the client-side cursor |
| `-d, --no-decorations` | Don't request window decorations |
| `-i, --shortcut-inhibit` | Inhibit compositor shortcuts while focused |
| `-s, --use-sw-renderer` | Software rendering (avoid; the laptop has a GPU) |

TigerVNC (`pacman -S tigervnc`) remains a fallback, with the `127.0.0.1` /
`127.0.0.1::5900` caveat from §1.

### 2.3 Open the display

Complete sequence, safe to paste into a fresh shell on the laptop — it derives
both addresses itself:

```bash
KEY="$HOME/.ssh/oir"
SSH="ssh -i $KEY -o IdentitiesOnly=yes \
         -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

RUNNER_IP=$(tailscale status --json \
  | jq -r '[.Peer[] | select(.HostName|startswith("github-runner-")) | select(.Online) | .TailscaleIPs[0]][0] // empty')
CIP=$($SSH runner@"$RUNNER_IP" \
        "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' jetbrainsmono")

$SSH -N -L 5900:"$CIP":5900 runner@"$RUNNER_IP" &
TUNNEL=$!
sleep 1

wlvncc 127.0.0.1
kill "$TUNNEL" 2>/dev/null
```

Notes on that block:

- `-N` means "tunnel only, no shell"; the `&` plus `kill` keeps it scoped to the
  client's lifetime.
- The forward target is `$CIP`, the **container**. `127.0.0.1` there is the runner
  host, where nothing listens.
- If port 5900 is taken locally, change both the `-L` left-hand side and the
  client argument.

### 2.4 Managing the display itself

Inside the container, the display is managed by `~/.local/bin/wayland-browser`
(deployed copy of `container/browser.sh`):

```bash
wayland-browser start [url]   # idempotent; relaunches chromium if it died
wayland-browser stop          # kills sway, wayvnc, chromium
wayland-browser restart [url] # stop + start  — kills all apps
wayland-browser status
wayland-browser shot [out.png]
```

Its environment knobs: `RES` (default `1440x900`), `VNC_PORT` (5900),
`VNC_MAX_FPS` (default 30), `BROWSER_URL`, `LOG` (`/tmp/wayland-remote`).

> **Known drift:** the deployed `~/.local/bin/wayland-browser` is stale relative
> to `container/browser.sh` (missing the `-f $VNC_MAX_FPS -p -L info` flags).
> `doc.sh` re-copies it on every container start. If you need the new flags
> *now*, `docker cp container/browser.sh jetbrainsmono:/home/jetbrain/.local/bin/wayland-browser`.

### The env prelude

Any direct interaction with the compositor needs this. From inside the container:

```bash
export XDG_RUNTIME_DIR=/tmp/xdg-1000 WAYLAND_DISPLAY=wayland-1
```

From the laptop, the full form:

```bash
ssh runner@<tailscale-ip> 'docker exec -u jetbrain jetbrainsmono bash -lc "
  export XDG_RUNTIME_DIR=/tmp/xdg-1000 WAYLAND_DISPLAY=wayland-1
  <command> "'
```

---

## 3. Playbooks

### 3.1 "Show me the screen"

```bash
wayland-browser shot /tmp/wayland-remote/shot.png   # prints the path
```

Then read the PNG. `grim` is installed and works headlessly; this is the fastest
way to answer "did it actually launch?" — far better than guessing from logs.

Check what is on screen and which window has focus:

```bash
swaymsg -s /tmp/xdg-1000/sway-ipc.1000.*.sock -t get_tree \
  | python3 -c 'import json,sys
d=json.load(sys.stdin)
def w(n):
    if n.get("type")=="con" and n.get("app_id"): print(n["app_id"],"|",n.get("name"))
    for c in n.get("nodes",[])+n.get("floating_nodes",[]): w(c)
w(d)'
```

### 3.2 "Open a URL"

```bash
wayland-browser start https://example.com
```

If sway is already up it relaunches only Chromium. Chromium is started maximised
on `--ozone-platform=wayland` with a dedicated profile at
`~/.cache/chromium-wayland`, so it never collides with a normal profile.

### 3.3 "Run Minecraft <version>"

`portablemc` is at `~/.local/bin/portablemc`; installs land in `~/.minecraft`.
Always resolve the version before launching — Mojang moved to `year.month`
versioning and the newest release is not `1.21.x` any more.

```bash
# what actually exists
curl -sS https://piston-meta.mojang.com/mc/game/version_manifest_v2.json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["latest"])'

# required Java for a specific version
curl -sS "$(curl -sS https://piston-meta.mojang.com/mc/game/version_manifest_v2.json \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print([v["url"] for v in d["versions"] if v["id"]=="26.3"][0])')" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["javaVersion"])'
```

Launch (adjust Java to what the version's metadata demands):

```bash
export XDG_RUNTIME_DIR=/tmp/xdg-1000 WAYLAND_DISPLAY=wayland-1
setsid nohup portablemc start -u Steve \
  --jvm /usr/lib/jvm/java-25-openjdk/bin/java \
  --resolution 960x540 26.3 >/tmp/mc263.log 2>&1 </dev/null &
```

Known requirements:

- **26.3 → Java 25.** Its metadata declares `javaVersion: 25`; JDK 21 fails.
- **1.21.11 → Java 21.** The default JVM on this box is 25, so pass the path
  explicitly for that version.
- `-u Steve` forces offline mode; there is no Microsoft login.
- 26.3 moved from GLFW to **SDL3** (`LWJGL 3.4.3`), and its `app_id` is
  `com.mojang.minecraft`. Anything keyed to `null`/GLFW behaviour from 1.21.x is
  now wrong.

Kill a game without killing yourself:

```bash
pkill -x java
```

### 3.4 "It's laggy / choppy"

**Do not guess. Read these three numbers first.**

```bash
# 1. What RTT does wayvnc itself see? (printed once per connection)
grep 'MIN-RTT' /tmp/wayland-remote/wayvnc.log | tail -1

# 2. Is the sender actually keeping up, and how much of each frame changed?
grep 'Frames captured' /tmp/wayland-remote/wayvnc.log | tail -5

# 3. Is the box CPU-saturated?
ps -o pid,pcpu,comm -C java 2>/dev/null; uptime
ss -tin | grep -A1 ':5900' | grep -o 'rtt:[0-9./]*'
```

Interpretation table:

| Reading | Meaning | Action |
|---|---|---|
| `MIN-RTT` > 100 ms | The WAN path, not the display stack | Fix the transport (§5); nothing local helps |
| `frames sent` ≈ `frames captured` ≈ 30 | wayvnc is keeping up; it is not the bottleneck | Look at RTT / damage |
| `frame damage` > 90 % | Full-screen churn; no inter-frame redundancy | Only fewer pixels or a different codec helps |
| `java` > 300 % CPU, load > 4 | llvmpipe is saturated; frame pacing is uneven | Lower resolution, cap the game's fps |
| `rtt` on `:5900` is ~0.1 ms, 0 retrans | The container→host hop is clean | The problem is past the host |

Measured on this box (2026-10-20, Minecraft fullscreen at 1440×900):

- `MIN-RTT during handshake was 267 ms` — this is Tailscale, not VNC
- `Frames captured: 30, frames sent: 30`, `frame damage: 96.7 %`
- ~5–6 Mbps outbound (≈750 KB/s), Tight encoding
- container→host hop: 135 µs RTT, 0 retransmits
- `java` at 335 % of 400 % CPU, load average 4.8
- Tailscale path: `via DERP(iad)`, 265–418 ms

**What actually helps, in order:**

1. **Get off DERP** (§5). At 267 ms, no remote desktop feels good; this is
   physics, not tuning.
2. **Cut pixels.** ~30 % fewer pixels removes ~30 % of the work from llvmpipe,
   sway's compositor, wayvnc's encoder *and* the wire simultaneously:
   ```bash
   swaymsg -s /tmp/xdg-1000/sway-ipc.1000.*.sock output HEADLESS-1 resolution 1280x720
   ```
   Reversible: `resolution 1440x900`.
3. **Match the frame rate to the stream.** A 45 fps source delivered through a
   30 fps cap drops frames unevenly and reads as judder. Cap the game to 30
   (Options → Video Settings → Max Framerate) — this also frees CPU on a
   saturated box, unlike raising the cap.
4. **Coalesce updates** with `-f`. This is wayvnc's only batching control: it
   holds damage for `1/fps` seconds and emits one update. Default 30.

**Things that do not exist, so do not promise them:**

- **There is no batch-size / frames-per-update option.** Not in the CLI
  (`wayvnc --help`), not in the live control socket (`wayvncctl` — it only does
  client list/disconnect, output switching, desktop name, exit), not in the
  config file. `-f` is the coalescing window and nothing else.
- **wayvnc does not "buffer N frames".** RFB already coalesces damage into a
  single update per frame; there is no second layer to tune.
- **Batching cannot rescue this workload anyway.** At 96.7 % damage, consecutive
  frames share almost no pixels, so merging them saves ~3 % of the bytes.
- **H.264 is available on both ends, and it is the one real bandwidth lever.**
  wayvnc links `libavcodec` + `libx264`, neatvnc 1.0.3 ships the `open-h264`
  encoder, and wlvncc accepts it explicitly:
  ```bash
  wlvncc -e open-h264 127.0.0.1
  ```
  Confirm what the server actually negotiated — the log names the encoder:
  ```bash
  grep 'Choosing' /tmp/wayland-remote/wayvnc.log | tail -1   # "Choosing h264" vs "Choosing tight encoding"
  ```
  Current sessions negotiate **tight**, so H.264 is untested here. Cost is real:
  x264 encoding burns CPU on a box already at 335 %, so measure `frames sent`
  and `java` CPU after switching rather than assuming it wins.

### 3.5 "I can't connect"

Work outward from the server, and derive every address:

```bash
# 1. server up?
ss -lnt | grep 5900

# 2. right tunnel target? ($SSH from §2.1)
CIP=$($SSH runner@"$RUNNER_IP" \
        "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' jetbrainsmono")
echo "$CIP"

# 3. who is connected right now?
wayvncctl client-list          # -S /tmp/xdg-1000/wayvncctl if it complains
```

Order of checks: wayvnc listening → `$CIP` is the container, not the host → the
client was given `127.0.0.1` without `:5900` → Tailscale peer is up:

```bash
tailscale ping "$RUNNER_IP"
```

Kick a wedged client without restarting anything:

```bash
wayvncctl client-disconnect <id>
```

### 3.6 "Change the resolution"

```bash
swaymsg -s /tmp/xdg-1000/sway-ipc.1000.*.sock output HEADLESS-1 resolution 1280x720
```

Live, no restart, no session loss. Fullscreen apps resize themselves. For a
persistent change, pass `RES=1280x720` to `wayland-browser start`.

### 3.7 Recording / capturing

`grim` for stills. For video, `wf-recorder` is not installed; installing it is
acceptable (it is Wayland-native and needs no X). Do not reach for `ffmpeg
-f x11grab`.

---

## 4. Transport: the actual problem

The user's laptop reaches the runner over Tailscale, and Tailscale cannot
establish a direct path. Measured: `via DERP(iad)` at 265–418 ms.

Diagnose from the laptop, not the container (there is no tailscale binary inside
it):

```bash
tailscale ping github-runner-<RUN_ID>
tailscale ping --until-direct -c 10 github-runner-<RUN_ID>
tailscale netcheck
```

What `netcheck` tells you:

- `UDP: false` → UDP is blocked; direct is impossible until that is fixed.
- `MappingVariesByDestIP: true` → hard/symmetric NAT (or CGNAT). Hole punching
  against another symmetric NAT fails.
- `Preferred DERP` and the per-region latency list → which relay is chosen and
  whether a closer one exists.

Realistic outcomes:

1. **Direct path works** → single-digit to low-double-digit ms. Done.
2. **UDP blocked locally** → open UDP 41641 outbound, enable UPnP/NAT-PMP on the
   router, retry. Sometimes that is all it takes.
3. **Both ends hard NAT** (likely: GitHub-hosted runners sit behind Azure NAT with
   no port forwarding) → direct is impossible. The only real fix is a
   **self-hosted `derper` on a VPS near the user**, added to the tailnet's ACL
   `derpMap`. That converts ~267 ms into ~20–40 ms.

Transport knobs worth trying on the client once, in the tunnel command:

```bash
-o IPQoS=throughput   # OpenSSH default marks interactive traffic lowdelay; carriers deprioritise it
-o Compression=no     # VNC data is already compressed; SSH compression adds CPU and latency
```

---

## 5. What to tell the user

The user is technical, impatient, and dislikes hand-waving. They read the raw
command output. Match that.

**Do:**

- Lead with measured numbers and the command that produced them. "wayvnc's own
  handshake log says 267 ms" beats "it seems slow".
- Separate *throughput* problems from *latency* problems; they have different
  fixes and only one of them is tunable.
- Say plainly when something cannot be fixed from inside the box.
- Offer one concrete action at a time, with the cost of doing it (e.g. "this
  drops your VNC connection for ~1 s").
- When a change touches their live session (restarting wayvnc, resizing the
  output, killing the game), say so **before** doing it.
- Correct yourself explicitly if an earlier claim turns out wrong.

**Don't:**

- Don't claim a feature exists without checking `--help` and the control socket.
  "Batch frames" was raised by the user; it turned out not to exist. Say that.
- Don't promise smoothness at 267 ms. No codec, resolution, or flag fixes RTT.
- Don't blame the game when the numbers show the relay, or vice versa. Both were
  real here: 335 % CPU *and* 267 ms.
- Don't suggest X11, Xvfb, Xwayland, or a TigerVNC server as a workaround.
- Don't suggest swapping the compositor to niri (or Hyprland, which also wants a
  DRM device). There is no headless backend and no `/dev/dri`; see §0.
- Don't suggest `doc.sh --reset` to "clean up" anything.

**Canonical framing for the lag question:**

> The display stack is healthy — wayvnc is sending 30 fps at 5–6 Mbps with zero
> retransmits on the container hop. The 267 ms hop is Tailscale relaying through
> DERP(iad) because no direct path exists. That latency sets the floor on how
> responsive anything can feel. Local tuning (resolution, frame-rate matching,
> coalescing) reduces queueing on top of it, but only a direct path or a closer
> relay removes the floor.

---

## 6. Current state (2026-10-20)

- Live run `39375053803`, Tailscale IP `100.89.137.17` (**this run only — resolve
  it per §2.1; it changes every dispatch**), tailnet hostname
  `github-runner-39375053803`. Container `172.17.0.2`, gateway `172.17.0.1`
  (same caveat: ask `docker inspect`).
- sway up on `HEADLESS-1` at 1440×900; wayvnc running as
  `wayvnc 0.0.0.0 5900 -p -L info` (counters on, default 30 fps).
- Minecraft 26.3 was launched and verified at 54 fps (menu, llvmpipe).
- Uncommitted in the repo: `container/doc.sh` (sway/wayvnc/grim/chromium + mesa,
  `setcap -r /usr/bin/sway`, `--init`, `-p 127.0.0.1:5900:5900`, post-start
  browser launch), and untracked `container/browser.sh`, `display.md`.
  `connect.sh` is clean — the `vnc` action was removed; it only opens a shell.
- `sway` must keep its `cap_sys_nice` stripped (`sudo setcap -r /usr/bin/sway`);
  Docker's capability bounding set rejects it at `execve` with
  `Operation not permitted`. It is baked into the image now — do not undo it.
- `niri 26.04` is installed in the *live* container as a result of the headless
  evaluation in §0. It is not in the image (`doc.sh`) and is not used. Leave it
  alone or `pacman -Rns niri`; do not build anything on it.

---

## 7. File map

| Path | Role |
|---|---|
| `.github/workflows/umm.yml` | Runner: Tailscale join, sshd, repo clone, background container prebuild |
| `connect.sh` | Laptop entry point: dispatch/reuse a runner, wait for Tailscale + sshd, attach to the container. Display access is separate (§2). |
| `container/doc.sh` | Image build + container lifecycle + shell attach |
| `container/browser.sh` | The display itself (deployed as `wayland-browser`) |
| `~/dev/wayland-remote/` | Older standalone scripts, superseded — do not use |
| `/tmp/wayland-remote/sway.log` | Compositor log |
| `/tmp/wayland-remote/wayvnc.log` | RFB log **and** the best diagnostics on the box |
| `/tmp/wayland-remote/chromium.log` | Browser log |

---

## 8. Thirty-second triage

```bash
export XDG_RUNTIME_DIR=/tmp/xdg-1000 WAYLAND_DISPLAY=wayland-1
ps -eo pid,stat,comm | awk '$2 !~ /^Z/ && $3 ~ /^(sway|wayvnc|chromium|java)$/'
ss -lnt | grep 5900
grep -E 'MIN-RTT|Frames captured' /tmp/wayland-remote/wayvnc.log | tail -3
swaymsg -s /tmp/xdg-1000/sway-ipc.1000.*.sock -t get_outputs | head -20
grim /tmp/wayland-remote/shot.png && echo ok
```

If all five are sane, the display is fine and the problem is the network.
