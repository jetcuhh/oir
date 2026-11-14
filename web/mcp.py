"""Minimal MCP server (Streamable HTTP, stateless) exposing the Oir container to Claude.

Built to be cheap in tokens:
  * three tools with one-line descriptions (tool schemas are re-sent every turn);
    file helpers (rd, edit, wr, gl, rg) are plain commands in the container
  * output has ANSI stripped, is capped, and keeps head + tail when cut
  * the full output of a cut command stays in the container (/tmp/out/N.log),
    so Claude greps/sed's it instead of you paying for it up front
  * `edit` sends only old/new text, never whole files, and replies "."
  * `get`/`put` move files. Text comes back inline; binaries and folders are
    copied to the runner (folders zipped) and handed back as a download link,
    because base64 would cost more tokens than the file is worth.

Auth: the connector URL is /mcp/<token>, token = HMAC(OIR_PASSWORD, "oir-mcp").
It is stable across runs and never needs a second secret. Claude's web connector UI
has no custom-header field, so the secret lives in the path.
"""
import asyncio
import hashlib
import hmac
import itertools
import json
import os
import re
from pathlib import Path
from urllib.parse import quote

from aiohttp import web

CONTAINER = os.environ.get("OIR_CONTAINER", "jetdafih")
USER = "jet"
WORKDIR = "/home/jet/dev"
DEFAULT_MAX = 3000          # chars returned per command unless Claude asks for more
HARD_MAX = 20000
MAX_TIMEOUT = 90            # Cloudflare cuts requests at ~100s; run long jobs with nohup
SHARE = Path("/tmp/oir-share")          # files copied out of the container for download
LINK_FILE = Path.home() / "link" / "url.txt"
CHUNK = 200_000             # bytes read from a file before it is shared instead of inlined
_ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\r")
_SEM = asyncio.Semaphore(4)
_ids = itertools.count(1)
_TOK = ""                   # file-download token, set once routes() knows the password

# Sent once on connect; MCP clients put this in Claude's context, so keep it tiny.
# Full rules live in ~/.agents/AGENTS.md.
INSTRUCTIONS = (
    "Minimalism: smallest change, no extras. Batch commands (a && b). "
    "Filter output (rg, head, tail, -q, --stat). No AI attribution in commits/PRs/code. "
    "First run `handoff` (resume notes); after each milestone `handoff add \"...\"`. "
    "Read ~/.agents/AGENTS.md. `tools` lists helpers."
)

# Runs inside the container: append the command (first 200 chars, one line) to the handoff
# trail, keep the last 200, then run it. `handoff` itself is not logged.
_RUN = r"""
case "$1" in handoff*) ;; *)
  d="$HOME/.handoff"; mkdir -p "$d"
  x="$(printf %s "${1:0:200}" | tr '\n' ' ')"
  printf '%s %s\n' "$(date +%H:%M)" "$x" >> "$d/cmds.log"
  tail -n 200 "$d/cmds.log" > "$d/c.tmp" && mv "$d/c.tmp" "$d/cmds.log" ;;
esac
exec timeout -k 2 "$2" bash -lc "$1"
"""

TOOLS = [
    {
        "name": "sh",
        "description": "Bash in the dev container (cwd ~/dev). Run `tools` for helpers.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "cmd": {"type": "string"},
                "timeout": {"type": "integer"},
                "max": {"type": "integer"},
            },
            "required": ["cmd"],
        },
    },
    {
        "name": "get",
        "description": "Read a file from the container. Folders are zipped and return a download link.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "max": {"type": "integer"},
            },
            "required": ["path"],
        },
    },
    {
        "name": "put",
        "description": "Write text to a file in the container; parent folders are created.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "content": {"type": "string"},
            },
            "required": ["path", "content"],
        },
    },
]


def token(password: str) -> str:
    return hmac.new(password.encode(), b"oir-mcp", hashlib.sha256).hexdigest()[:32]


def _env() -> dict:
    """GitHub token for gh/git in the container, passed by name so it never shows in `ps`."""
    env = dict(os.environ)
    if not env.get("GITHUB_TOKEN"):
        try:
            env["GITHUB_TOKEN"] = (Path.home() / ".token").read_text().strip()
        except OSError:
            pass
    return env


async def _docker(args: list[str], stdin: bytes | None = None, timeout: float = 30) -> tuple[int, bytes]:
    proc = await asyncio.create_subprocess_exec(
        "docker", "exec", "-i", "-u", USER, "-w", WORKDIR, "-e", "GITHUB_TOKEN", CONTAINER, *args,
        env=_env(), stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    try:
        out, _ = await asyncio.wait_for(proc.communicate(stdin), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        return 124, b"timed out"
    return proc.returncode or 0, out


def _clip(text: str, limit: int) -> tuple[str, int]:
    if len(text) <= limit:
        return text, 0
    head = limit * 2 // 5
    tail = limit - head
    top, bot = text[:head], text[-tail:]
    if (i := top.rfind("\n")) > 0:
        top = top[:i]
    if (j := bot.find("\n")) >= 0:
        bot = bot[j + 1:]
    cut = len(text) - len(top) - len(bot)
    return f"{top}\n[... {cut} chars cut ...]\n{bot}", cut


async def tool_sh(a: dict) -> tuple[str, bool]:
    cmd = str(a.get("cmd", ""))
    timeout = max(1, min(int(a.get("timeout") or 60), MAX_TIMEOUT))
    limit = max(200, min(int(a.get("max") or DEFAULT_MAX), HARD_MAX))
    async with _SEM:
        code, raw = await _docker(["bash", "-c", _RUN, "_", cmd, str(timeout)], timeout=timeout + 10)
    text = _ANSI.sub("", raw.decode("utf-8", "replace")).strip("\n")
    shown, cut = _clip(text, limit)
    if cut:
        n = next(_ids)
        path = f"/tmp/out/{os.getpid()}-{n}.log"
        code, _ = await _docker(["bash", "-c", f"mkdir -p /tmp/out && cat > {path}"], stdin=raw)
        if code == 0:
            shown += f"\n[full: {path}]"
    if code == 124 and not text.endswith("timed out"):
        shown += f"\n[timeout {timeout}s]"
    elif code:
        shown = f"[exit {code}]\n{shown}"
    return shown or ".", False


def _url(name: str) -> str:
    """Public link for a shared file; falls back to the local path without a tunnel."""
    try:
        base = next(iter(LINK_FILE.read_text().split()), "")
    except OSError:
        base = ""
    return f"{base.rstrip('/')}/f/{_TOK}/{quote(name)}" if base else str(SHARE / name)


async def _copy_out(src: str, name: str) -> str:
    SHARE.mkdir(parents=True, exist_ok=True)
    try:
        proc = await asyncio.create_subprocess_exec(
            "docker", "cp", f"{CONTAINER}:{src}", str(SHARE / name),
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
        _, err = await asyncio.wait_for(proc.communicate(), 120)
    except (OSError, asyncio.TimeoutError):
        return "copy failed"
    return "" if proc.returncode == 0 else err.decode("utf-8", "replace").strip()[-200:]


async def tool_get(a: dict) -> tuple[str, bool]:
    path = str(a.get("path", "")).strip()
    limit = max(200, min(int(a.get("max") or DEFAULT_MAX), HARD_MAX))
    if not path:
        return "path required", True
    # docker cp resolves relative paths against /, so work with the absolute one.
    code, out = await _docker(["bash", "-c",
        'p="$(readlink -f -- "$1")" && '
        '{ if [ -d "$p" ]; then echo "dir $p"; elif [ -f "$p" ]; then echo "file $p"; fi; }',
        "_", path])
    kind, _, path = out.decode("utf-8", "replace").strip().partition(" ")
    if code or kind not in ("dir", "file"):
        return f"not found: {path or a.get('path')}", True
    base = os.path.basename(path) or "files"

    if kind == "dir":
        name = base + ".zip"
        code, out = await _docker(["bash", "-c",
            'mkdir -p /tmp/out && cd "$(dirname "$1")" && zip -qr "/tmp/out/$2" "$(basename "$1")"',
            "_", path, name])
        if code:
            return out.decode("utf-8", "replace").strip()[-300:] or f"zip failed ({code})", True
        err = await _copy_out(f"/tmp/out/{name}", name)
        return (err, True) if err else (_url(name), False)

    code, raw = await _docker(["head", "-c", str(CHUNK), "--", path])
    if code:
        return raw.decode("utf-8", "replace").strip()[-300:] or f"read failed ({code})", True
    if b"\0" in raw[:8192]:                # binary: the link is the only useful form
        err = await _copy_out(path, base)
        return (err, True) if err else (_url(base), False)
    shown, cut = _clip(raw.decode("utf-8", "replace"), limit)
    if cut or len(raw) >= CHUNK:
        if not (err := await _copy_out(path, base)):
            shown += f"\n[full: {_url(base)}]"
    return shown or ".", False


async def tool_put(a: dict) -> tuple[str, bool]:
    path = str(a.get("path", "")).strip()
    data = a.get("content")
    if not path or not isinstance(data, str):
        return "path and content required", True
    code, out = await _docker(["bash", "-c", 'mkdir -p "$(dirname "$1")" && cat > "$1"', "_", path],
                              stdin=data.encode())
    if code:
        return out.decode("utf-8", "replace").strip()[-300:] or f"exit {code}", True
    return ".", False


HANDLERS = {"sh": tool_sh, "get": tool_get, "put": tool_put}


async def _handle(msg: dict) -> dict | None:
    if not isinstance(msg, dict):
        return {"jsonrpc": "2.0", "id": None,
                "error": {"code": -32600, "message": "invalid request"}}
    mid, method = msg.get("id"), msg.get("method", "")
    if mid is None:                       # notification: no reply
        return None

    def ok(result):
        return {"jsonrpc": "2.0", "id": mid, "result": result}

    def err(code, text):
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": text}}

    if method == "initialize":
        ver = (msg.get("params") or {}).get("protocolVersion") or "2025-03-26"
        return ok({
            "protocolVersion": ver,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "oir", "version": "1"},
            "instructions": INSTRUCTIONS,
        })
    if method == "ping":
        return ok({})
    if method == "tools/list":
        return ok({"tools": TOOLS})
    if method == "tools/call":
        p = msg.get("params") or {}
        fn = HANDLERS.get(p.get("name"))
        if not fn:
            return err(-32602, "unknown tool")
        try:
            text, is_err = await fn(p.get("arguments") or {})
        except Exception as e:            # keep the connector alive on any bad call
            text, is_err = f"{type(e).__name__}: {e}"[:300], True
        return ok({"content": [{"type": "text", "text": text}], "isError": is_err})
    return err(-32601, "method not found")


def routes(password: str) -> list[web.RouteDef]:
    global _TOK
    tok = token(password)
    _TOK = tok

    async def endpoint(request: web.Request) -> web.Response:
        if not hmac.compare_digest(request.match_info["tok"].encode(), tok.encode()):
            return web.Response(status=404)           # look like nothing is here
        try:
            body = await request.json()
        except Exception:
            return web.json_response({"error": "bad json"}, status=400)
        batch = body if isinstance(body, list) else [body]
        replies = [r for r in await asyncio.gather(*(_handle(m) for m in batch)) if r]
        if not replies:
            return web.Response(status=202)
        return web.json_response(replies if isinstance(body, list) else replies[0])

    async def not_allowed(request: web.Request) -> web.Response:
        return web.Response(status=405, headers={"Allow": "POST"})

    async def download(request: web.Request) -> web.Response:
        name = request.match_info["name"]
        if not hmac.compare_digest(request.match_info["tok"].encode(), tok.encode()) \
           or (SHARE / name).name != name:
            return web.Response(status=404)
        p = SHARE / name
        if not p.is_file():
            return web.Response(status=404)
        safe = name.replace('"', "")
        return web.FileResponse(p, headers={"Content-Disposition": f'attachment; filename="{safe}"'})

    return [web.post("/mcp/{tok}", endpoint), web.get("/mcp/{tok}", not_allowed),
            web.get("/f/{tok}/{name}", download)]


def publish_token(password: str) -> None:
    """Leave the token where the runner shell can print the connector URL."""
    p = Path.home() / "mcp.token"
    p.write_text(token(password))
    p.chmod(0o600)
