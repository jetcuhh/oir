#!/usr/bin/env python3
"""Password-protected web terminal.

Serves a ghostty-web page and bridges a WebSocket to one persistent PTY, so a
browser tab that reloads or reconnects lands back in the same shell.

Environment:
  OIR_PASSWORD  required, at least 6 characters
  OIR_CMD       command to run in the PTY      (default: bash web/session.sh)
  OIR_CWD       directory to run it in         (default: repo root)
  HOST / PORT   listen address                 (default: 127.0.0.1:7681)

Only ever bind to loopback and put a tunnel in front of it.
"""
import asyncio
import fcntl
import hmac
import json
import os
import re
import pty
import secrets
import signal
import struct
import termios
import time
from pathlib import Path

from aiohttp import WSMsgType, web

import mcp

HERE = Path(__file__).resolve().parent
DIST = HERE / "node_modules" / "ghostty-web" / "dist"
FONTS = HERE / "fonts"
NOVNC = HERE / "node_modules" / "@novnc" / "novnc"

HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "7681"))
PASSWORD = os.environ.get("OIR_PASSWORD", "")
VNC_PORT = int(os.environ.get("VNC_PORT", "5900"))
CONTAINER = os.environ.get("OIR_CONTAINER", "jetdafih")
CMD = os.environ.get("OIR_CMD", "bash web/session.sh")
CWD = os.environ.get("OIR_CWD", str(HERE.parent))

SCROLLBACK = 256 * 1024
MAX_BACKLOG = 4 * 1024 * 1024   # unsent bytes per browser before it is dropped and resyncs
TOKEN_TTL = 8 * 3600
MAX_TABS = 12

# The GitHub Actions run this server lives in (all unset when run locally).
RUN_ID = os.environ.get("GITHUB_RUN_ID", "")
REPO = os.environ.get("GITHUB_REPOSITORY", "")
CANCEL_TOKEN = os.environ.get("OIR_CANCEL_TOKEN", "")
RUN_LIMIT = int(os.environ.get("OIR_LIMIT_SECONDS", str(6 * 3600)))
STARTED_FILE = Path(os.environ.get("OIR_STARTED_FILE", str(Path.home() / "oir.started")))
BOOTED = time.time()

# Where the background container build writes its log (see the workflow).
PREBUILD_LOG = Path(os.environ.get("OIR_PREBUILD_LOG", str(Path.home() / "prebuild.log")))

# Plain-English names for the Dockerfile steps, matched against the RUN command.
STEP_LABELS = [
    (r"pacman -Syu", "installing system packages"),
    (r"setcap", "configuring sway"),
    (r"archlinux-java", "setting up Java"),
    (r"useradd", "creating the user"),
    (r"rustup", "installing Rust"),
    (r"pi install", "installing the pi extension"),
    (r"npm install -g|opencode", "installing coding agents"),
    (r"config\.fish", "configuring fish"),
    (r"nushell", "configuring nushell"),
    (r"x\.ai/cli", "installing the xAI CLI"),
    (r"dpath", "installing dpath"),
    (r"lantern", "installing lantern"),
    (r"oshi", "building oshi"),
    (r"flint", "building flint"),
]
_ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
_STEP_BUILDKIT = re.compile(r"^#\d+ \[\s*(\d+)/(\d+)\]\s+(.*)$")
_STEP_LEGACY = re.compile(r"^Step (\d+)/(\d+) : (.*)$")
_OUT_LINE = re.compile(r"^#\d+ \d+\.\d+ (.+)$")
MAX_FAILS = 5
LOCKOUT_SECONDS = 300
GLOBAL_MAX_FAILS = 20      # across all addresses, so many IPs can't dodge the limit
GLOBAL_WINDOW = 600
COOKIE = "oir"

TOKENS: dict[str, float] = {}   # token -> expiry (monotonic)
FAILS: dict[str, tuple[int, float]] = {}
GLOBAL_FAILS: list[float] = []


def client_ip(request: web.Request) -> str:
    # Cloudflare sets this header and overwrites any value the client sent.
    return request.headers.get("CF-Connecting-IP") or request.remote or "?"


def is_authed(request: web.Request) -> bool:
    token = request.cookies.get(COOKIE, "")
    exp = TOKENS.get(token)
    if exp is None:
        return False
    if exp < time.monotonic():
        TOKENS.pop(token, None)
        return False
    return True


def same_origin(request: web.Request) -> bool:
    origin = request.headers.get("Origin")
    if not origin:
        return False
    return origin.split("://", 1)[-1] == request.headers.get("Host")


class Client:
    def __init__(self, ws: web.WebSocketResponse):
        self.ws = ws
        self.queue: asyncio.Queue = asyncio.Queue()
        self.backlog = 0            # bytes queued but not yet sent
        self.dropped = False
        self.task = asyncio.ensure_future(self._pump())

    async def _pump(self) -> None:
        try:
            while True:
                kind, payload = await self.queue.get()
                if kind == "bin":
                    await self.ws.send_bytes(payload)
                    self.backlog -= len(payload)
                else:
                    await self.ws.send_str(payload)
        except (asyncio.CancelledError, ConnectionResetError):
            pass

    def _drop(self) -> None:
        # A browser that can't keep up would otherwise make this queue grow without
        # bound. Cut it loose; the page reconnects and gets the scrollback replayed.
        self.dropped = True
        self.queue = asyncio.Queue()
        self.backlog = 0
        asyncio.ensure_future(self.ws.close())

    def send_bytes(self, data: bytes) -> None:
        if self.dropped:
            return
        if self.backlog + len(data) > MAX_BACKLOG:
            self._drop()
            return
        self.backlog += len(data)
        self.queue.put_nowait(("bin", data))

    def send_json(self, obj: dict) -> None:
        if not self.dropped:
            self.queue.put_nowait(("txt", json.dumps(obj)))

    def close(self) -> None:
        self.task.cancel()


class Session:
    """One shell (a tab), shared by every browser that has it open."""

    def __init__(self, name: str = "term") -> None:
        self.name = name
        self.pid: int | None = None
        self.fd: int | None = None
        self.clients: set[Client] = set()
        self.scrollback = bytearray()
        self.pending = bytearray()
        self.writer_on = False

    @property
    def alive(self) -> bool:
        return self.pid is not None

    def spawn(self, cols: int, rows: int) -> None:
        pid, fd = pty.fork()
        if pid == 0:
            try:
                fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
                os.chdir(CWD)
                env = dict(os.environ, TERM="xterm-256color", COLORTERM="truecolor")
                env.pop("OIR_PASSWORD", None)
                os.execvpe("bash", ["bash", "-lc", CMD], env)
            except BaseException:
                pass
            os._exit(127)
        self.pid, self.fd = pid, fd
        self.scrollback.clear()
        os.set_blocking(fd, False)
        asyncio.get_running_loop().add_reader(fd, self._on_readable)

    def _on_readable(self) -> None:
        try:
            data = os.read(self.fd, 65536)
        except BlockingIOError:
            return
        except OSError:
            data = b""
        if not data:
            self._reap()
            return
        # fish 4 asks the terminal for its attributes (DA1) at startup and waits 10s if nothing
        # answers. The browser terminal doesn't, so answer for it.
        if b"\x1b[c" in data or b"\x1b[0c" in data:
            self.write(b"\x1b[?62;22c")
        self.scrollback += data
        # Trim in big steps: deleting from the front of a bytearray copies the rest,
        # so doing it on every read burns CPU under heavy output.
        if len(self.scrollback) > SCROLLBACK * 2:
            del self.scrollback[: len(self.scrollback) - SCROLLBACK]
        for c in list(self.clients):
            c.send_bytes(data)

    def _reap(self) -> None:
        loop = asyncio.get_running_loop()
        loop.remove_reader(self.fd)
        if self.writer_on:
            loop.remove_writer(self.fd)
            self.writer_on = False
        try:
            os.close(self.fd)
        except OSError:
            pass
        code = 0
        try:
            _, status = os.waitpid(self.pid, 0)
            code = os.waitstatus_to_exitcode(status)
        except ChildProcessError:
            pass
        self.pid = self.fd = None
        self.pending.clear()
        self.scrollback.clear()
        for c in list(self.clients):
            c.send_json({"type": "exit", "code": code})

    def write(self, data: bytes) -> None:
        if not self.alive:
            return
        self.pending += data
        self._flush()

    def _flush(self) -> None:
        loop = asyncio.get_running_loop()
        while self.pending and self.alive:
            try:
                n = os.write(self.fd, self.pending)
            except BlockingIOError:
                if not self.writer_on:
                    loop.add_writer(self.fd, self._flush)
                    self.writer_on = True
                return
            except OSError:
                self.pending.clear()
                return
            del self.pending[:n]
        if self.writer_on and self.alive:
            loop.remove_writer(self.fd)
            self.writer_on = False

    def resize(self, cols: int, rows: int) -> None:
        if not self.alive:
            self.spawn(cols, rows)
            return
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def kill(self) -> None:
        # The shell is a session leader, so its pid is also its process group id.
        # Signal the group: the docker-exec child holds the pty open, and without
        # this the shell would never see EOF and would leak.
        if not self.alive:
            return
        pid = self.pid
        for sig, delay in ((signal.SIGHUP, 0), (signal.SIGKILL, 3)):
            if delay:
                asyncio.get_running_loop().call_later(delay, self._signal, pid, sig)
            else:
                self._signal(pid, sig)

    @staticmethod
    def _signal(pid: int, sig: int) -> None:
        try:
            os.killpg(pid, sig)
        except (ProcessLookupError, PermissionError):
            pass

    def shutdown(self) -> None:
        self.kill()
        for c in list(self.clients):
            asyncio.ensure_future(c.ws.close())


SESSIONS: dict[str, Session] = {}
_tab_counter = 0


def new_session() -> tuple[str, Session]:
    global _tab_counter
    _tab_counter += 1
    sid = secrets.token_hex(4)
    SESSIONS[sid] = Session(f"term {_tab_counter}")
    return sid, SESSIONS[sid]


def tab_json(sid: str, s: Session) -> dict:
    return {"id": sid, "name": s.name, "alive": s.alive}


async def index(request: web.Request) -> web.Response:
    return web.Response(
        body=(HERE / "index.html").read_bytes(),
        content_type="text/html",
        headers={"Cache-Control": "no-store"},
    )


async def healthz(request: web.Request) -> web.Response:
    return web.Response(text="ok")


async def me(request: web.Request) -> web.Response:
    return web.json_response({"ok": is_authed(request)})


async def login(request: web.Request) -> web.Response:
    if not same_origin(request):
        return web.json_response({"error": "bad origin"}, status=403)
    ip = client_ip(request)
    now = time.monotonic()
    GLOBAL_FAILS[:] = [x for x in GLOBAL_FAILS if now - x < GLOBAL_WINDOW]
    for k in [k for k, (_, until) in FAILS.items() if until < now]:
        del FAILS[k]
    count, locked_until = FAILS.get(ip, (0, 0.0))
    if len(GLOBAL_FAILS) >= GLOBAL_MAX_FAILS:
        return web.json_response({"error": "too many attempts, try later"}, status=429)
    if count >= MAX_FAILS and now < locked_until:
        return web.json_response({"error": "too many attempts, try later"}, status=429)
    try:
        data = await request.json()
    except Exception:
        data = {}
    given = str(data.get("password", "")).encode()
    if hmac.compare_digest(given, PASSWORD.encode()):
        FAILS.pop(ip, None)
        for t in [t for t, e in TOKENS.items() if e < now]:
            del TOKENS[t]
        token = secrets.token_urlsafe(32)
        TOKENS[token] = now + TOKEN_TTL
        resp = web.json_response({"ok": True})
        resp.set_cookie(
            COOKIE,
            token,
            httponly=True,
            samesite="Strict",
            secure=request.headers.get("X-Forwarded-Proto") == "https",
            path="/",
            max_age=TOKEN_TTL,
        )
        return resp
    if count >= MAX_FAILS:
        count = 0  # lockout expired
    FAILS[ip] = (count + 1, now + LOCKOUT_SECONDS)
    GLOBAL_FAILS.append(now)
    await asyncio.sleep(1)
    return web.json_response({"error": "wrong password"}, status=401)


async def tabs_list(request: web.Request) -> web.Response:
    if not is_authed(request):
        return web.Response(status=401)
    return web.json_response({"tabs": [tab_json(i, s) for i, s in SESSIONS.items()]})


async def tabs_create(request: web.Request) -> web.Response:
    if not is_authed(request):
        return web.Response(status=401)
    if not same_origin(request):
        return web.json_response({"error": "bad origin"}, status=403)
    if len(SESSIONS) >= MAX_TABS:
        return web.json_response({"error": f"max {MAX_TABS} tabs"}, status=429)
    sid, s = new_session()
    return web.json_response(tab_json(sid, s))


async def tabs_close(request: web.Request) -> web.Response:
    if not is_authed(request):
        return web.Response(status=401)
    if not same_origin(request):
        return web.json_response({"error": "bad origin"}, status=403)
    s = SESSIONS.pop(request.match_info["id"], None)
    if s is None:
        return web.json_response({"error": "no such tab"}, status=404)
    s.shutdown()
    return web.json_response({"ok": True})


def run_left() -> int | None:
    """Seconds until the run's time limit, or None when not running in Actions."""
    if not RUN_ID:
        return None
    try:
        started = float(STARTED_FILE.read_text().strip())
    except (OSError, ValueError):
        started = BOOTED
    return max(0, int(started + RUN_LIMIT - time.time()))


def build_progress() -> dict:
    """Where the container build is, read from the end of its log."""
    try:
        with open(PREBUILD_LOG, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 200_000))
            text = f.read().decode("utf-8", "replace")
    except OSError:
        return {"state": "waiting"}
    lines = [_ANSI.sub("", l).rstrip() for l in text.splitlines()]

    if any(l == "Oir container is ready." for l in lines):
        return {"state": "ready"}

    step = total = 0
    cmd = last = ""
    for l in lines:
        m = _STEP_BUILDKIT.match(l) or _STEP_LEGACY.match(l)
        if m:
            step, total, cmd = int(m.group(1)), int(m.group(2)), m.group(3)
            last = ""          # output of the previous step is stale now
        m = _OUT_LINE.match(l)
        if m:
            last = m.group(1)

    if any(l.startswith(("Image built.", "Starting container")) for l in lines):
        return {"state": "starting"}
    if total:
        label = next((lab for rx, lab in STEP_LABELS if re.search(rx, cmd)), cmd[:48])
        return {"state": "building", "step": step, "of": total, "label": label, "line": last[:100]}
    if any(l.startswith("Building image") for l in lines):
        return {"state": "building", "label": "pulling the base image"}
    return {"state": "waiting"}


async def build_status(request: web.Request) -> web.Response:
    # Unauthenticated on purpose: connect.sh polls it before you have logged in. It only
    # says how far the container build has got.
    info = build_progress()
    body = "".join(f"{k}={v}\n" for k, v in info.items())
    return web.Response(text=body, content_type="text/plain", headers={"Cache-Control": "no-store"})


async def run_info(request: web.Request) -> web.Response:
    if not is_authed(request):
        return web.Response(status=401)
    return web.json_response({
        "left": run_left(),
        "stoppable": bool(RUN_ID and REPO and CANCEL_TOKEN),
    })


async def run_stop(request: web.Request) -> web.Response:
    if not is_authed(request):
        return web.Response(status=401)
    if not same_origin(request):
        return web.json_response({"error": "bad origin"}, status=403)
    if not (RUN_ID and REPO and CANCEL_TOKEN):
        return web.json_response({"error": "can't stop it from here"}, status=400)
    try:
        proc = await asyncio.create_subprocess_exec(
            "gh", "run", "cancel", RUN_ID, "-R", REPO,
            env=dict(os.environ, GH_TOKEN=CANCEL_TOKEN),
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        code = await asyncio.wait_for(proc.wait(), timeout=30)
    except (OSError, asyncio.TimeoutError):
        return web.json_response({"error": "cancel failed"}, status=502)
    if code != 0:
        return web.json_response({"error": "cancel failed"}, status=502)
    return web.json_response({"ok": True})


async def ws_handler(request: web.Request) -> web.StreamResponse:
    if not is_authed(request):
        return web.Response(status=401)
    if not same_origin(request):
        return web.Response(status=403)
    session = SESSIONS.get(request.query.get("tab", ""))
    if session is None:
        return web.Response(status=404)

    ws = web.WebSocketResponse(heartbeat=20, max_msg_size=1 << 20)
    await ws.prepare(request)
    client = Client(ws)
    if session.alive and session.scrollback:
        client.send_bytes(bytes(session.scrollback))
    session.clients.add(client)
    try:
        async for msg in ws:
            if msg.type == WSMsgType.BINARY:
                session.write(msg.data)
            elif msg.type == WSMsgType.TEXT:
                try:
                    ctrl = json.loads(msg.data)
                    if ctrl.get("type") == "resize":
                        cols, rows = int(ctrl["cols"]), int(ctrl["rows"])
                        if 1 <= cols <= 1000 and 1 <= rows <= 1000:
                            session.resize(cols, rows)
                except (ValueError, KeyError, TypeError):
                    pass
    finally:
        session.clients.discard(client)
        client.close()
    return ws


async def display(request: web.Request) -> web.Response:
    if not is_authed(request):
        raise web.HTTPFound("/")
    return web.Response(
        body=(HERE / "display.html").read_bytes(),
        content_type="text/html",
        headers={"Cache-Control": "no-store"},
    )


VNC_START = asyncio.Lock()


async def vnc_open() -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    # The desktop isn't started with the container; start it on first use.
    # Don't probe the port: docker's published 127.0.0.1:5900 accepts connections
    # even when nothing listens behind it. `start` is a no-op when already up.
    async with VNC_START:
        proc = await asyncio.create_subprocess_exec(
            "docker", "exec", "-u", "jet", "-e", f"VNC_PORT={VNC_PORT}", CONTAINER,
            "wayland-browser", "start",
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        await asyncio.wait_for(proc.wait(), 60)
    return await asyncio.open_connection("127.0.0.1", VNC_PORT)


async def vnc_handler(request: web.Request) -> web.StreamResponse:
    if not is_authed(request):
        return web.Response(status=401)
    if not same_origin(request):
        return web.Response(status=403)
    try:
        reader, writer = await vnc_open()
    except (OSError, asyncio.TimeoutError):
        return web.Response(status=502)

    ws = web.WebSocketResponse(heartbeat=20, protocols=("binary",), max_msg_size=1 << 22)
    await ws.prepare(request)

    async def pump() -> None:
        try:
            while data := await reader.read(65536):
                await ws.send_bytes(data)
        finally:
            await ws.close()

    task = asyncio.create_task(pump())
    try:
        async for msg in ws:
            if msg.type == WSMsgType.BINARY:
                writer.write(msg.data)
                await writer.drain()
    finally:
        task.cancel()
        writer.close()
    return ws


async def on_cleanup(app: web.Application) -> None:
    for s in list(SESSIONS.values()):
        s.kill()


def make_app() -> web.Application:
    app = web.Application()
    app.router.add_get("/", index)
    app.router.add_get("/healthz", healthz)
    app.router.add_get("/api/me", me)
    app.router.add_post("/api/login", login)
    app.router.add_get("/api/tabs", tabs_list)
    app.router.add_post("/api/tabs", tabs_create)
    app.router.add_delete("/api/tabs/{id}", tabs_close)
    app.router.add_get("/api/status", build_status)
    app.router.add_get("/api/run", run_info)
    app.router.add_post("/api/stop", run_stop)
    app.router.add_get("/ws", ws_handler)
    app.router.add_get("/display", display)
    app.router.add_get("/vnc", vnc_handler)
    app.router.add_static("/novnc", NOVNC)
    app.router.add_static("/static", DIST)
    FONTS.mkdir(exist_ok=True)
    app.router.add_static("/fonts", FONTS)
    app.add_routes(mcp.routes(PASSWORD))
    app.on_cleanup.append(on_cleanup)
    return app


if __name__ == "__main__":
    if len(PASSWORD) < 6:
        raise SystemExit("OIR_PASSWORD must be set and at least 6 characters long")
    if not DIST.is_dir():
        raise SystemExit(f"{DIST} missing. Run: npm install   (in {HERE})")
    mcp.publish_token(PASSWORD)
    web.run_app(make_app(), host=HOST, port=PORT, print=None, access_log=None)
