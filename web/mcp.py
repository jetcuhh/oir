"""Minimal MCP server (Streamable HTTP, stateless) exposing the Oir container to Claude.

Built to be cheap in tokens:
  * ONE tool with a one-line description (tool schemas are re-sent every turn);
    file helpers (rd, edit, wr, gl, rg) are plain commands in the container
  * output has ANSI stripped, is capped, and keeps head + tail when cut
  * the full output of a cut command stays in the container (/tmp/out/N.log),
    so Claude greps/sed's it instead of you paying for it up front
  * `edit` sends only old/new text, never whole files, and replies "."

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

from aiohttp import web

CONTAINER = os.environ.get("OIR_CONTAINER", "jetdafih")
USER = "jet"
WORKDIR = "/home/jet/dev"
DEFAULT_MAX = 3000          # chars returned per command unless Claude asks for more
HARD_MAX = 20000
MAX_TIMEOUT = 90            # Cloudflare cuts requests at ~100s; run long jobs with nohup
_ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\r")
_SEM = asyncio.Semaphore(4)
_ids = itertools.count(1)

# Sent once on connect; MCP clients put this in Claude's context, so keep it tiny.
# Full rules live in ~/.agents/AGENTS.md.
INSTRUCTIONS = (
    "Minimalism: smallest change, no extras. Batch commands (a && b). "
    "Filter output (rg, head, tail, -q, --stat). No AI attribution in commits/PRs/code. "
    "First run `handoff` (resume notes); after each milestone `handoff add \"...\"`. "
    "`tools` lists helpers."
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
        await _docker(["bash", "-c", f"mkdir -p /tmp/out && cat > {path}"], stdin=raw)
        shown += f"\n[full: {path}]"
    if code == 124 and not text.endswith("timed out"):
        shown += f"\n[timeout {timeout}s]"
    elif code:
        shown = f"[exit {code}]\n{shown}"
    return shown or ".", False


HANDLERS = {"sh": tool_sh}


async def _handle(msg: dict) -> dict | None:
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
    tok = token(password)

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

    return [web.post("/mcp/{tok}", endpoint), web.get("/mcp/{tok}", not_allowed)]


def publish_token(password: str) -> None:
    """Leave the token where the runner shell can print the connector URL."""
    p = Path.home() / "mcp.token"
    p.write_text(token(password))
    p.chmod(0o600)
