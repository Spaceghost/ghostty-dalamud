#!/usr/bin/env python3
"""A stand-in for XivMcp, the loader and `/term selftest`, for CI without a game.

tools/ci/ingame-dryrun.sh starts it; nothing in the repository talks to it at
run time. It exists so tools/ci/ingame.sh and .github/workflows/ingame.yml are
exercised on an ordinary runner: every request the real script makes is
answered here, and the two things the game would do -- the loader swapping in a
new ghostty_core.dll, and `/term selftest` writing its report -- are simulated.

  tools/ci/mock-xivmcp.py --plugin-dir DIR --config-dir DIR --build-id ID
                          [--commit SHA] [--token TOK] [--mode MODE]
                          [--port N] [--port-file FILE] [--ready-file FILE]

Modes, which is how the dry run covers the paths that matter:

  pass       every case passes                      ingame.sh exits 0
  fail       one case fails                         ingame.sh exits 1
  nogame     the endpoint refuses to answer at all  ingame.sh exits 3
  noplayer   get_player is an error (title screen)  ingame.sh exits 3
  noswap     the loader never picks the core up     ingame.sh exits 1
  stale      the self-test reports an older build   ingame.sh exits 1

It is deliberately strict about the things a real deployment must get right, so
a regression in ingame.sh shows up as a dry-run failure:

  * every request must carry `Authorization: Bearer <token>`; anything else is
    401. The token is only ever compared, never logged.
  * every request after `initialize` must carry that session's Mcp-Session-Id.
  * `execute_command` accepts exactly `/term selftest` and `/term selftest
    <suites>` and refuses anything else, which is the allowlist the real
    XivMcp client `ghostty-ci` is configured with.

Not a fixture of the real protocol: it answers the subset ingame.sh uses, in
the shape ingame.sh reads. It is not evidence about the game.
"""

import argparse
import json
import os
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {}


def selftest_report(build_id, commit, run_id, failing=False):
    """A report in the shape core/app/selftest.nelua writes (docs/CI.md)."""
    cases = [
        ("core", "active", "pass", ""),
        ("core", "build stamp", "pass", ""),
        ("terminal", "vt bytes", "pass", ""),
        ("render", "draw hash", "pass", ""),
        ("settings", "round trip", "pass", ""),
        ("themes", "switch back", "pass", ""),
        ("bell", "styles", "pass", ""),
        ("world", "camera", "skip", "no character logged in"),
        ("agent", "marker", "skip", "the agent is off"),
        ("loader", "swap", "pass", ""),
    ]
    if failing:
        cases[3] = ("render", "draw hash", "fail",
                    "draw hash 0xdeadbeef, expected SELFTEST_RENDER_HASH 0xfeedface")
    passed = sum(1 for c in cases if c[2] == "pass")
    failed = sum(1 for c in cases if c[2] == "fail")
    skipped = sum(1 for c in cases if c[2] == "skip")
    return {
        "run_id": run_id,
        "complete": True,
        "ok": failed == 0,
        "state": "done",
        "suites": "all",
        "build": {"id": build_id, "commit": commit, "plugin": "0.0.0-mock"},
        "game": {"version": "0000.00.00.0000.0000", "platform": "mock"},
        "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "summary": {"passed": passed, "failed": failed, "skipped": skipped, "ms": 123},
        "cases": [
            {"suite": s, "case": c, "status": st, "ms": 1, "message": m}
            for s, c, st, m in cases
        ],
    }


def write_json(path, obj):
    """Write beside the target and rename over it, as the game's writes are."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def loader_thread(args, stop):
    """The loader: when ghostty_core.dll is written, the new core reports in.

    tools/ci/ingame.sh waits for selftest/core-loaded.json to be newer than its
    install and to name the build it just copied in, so this is the only thing
    that lets the dry run past step 4.
    """
    core = os.path.join(args.plugin_dir, "ghostty_core.dll")
    try:
        before = os.stat(core).st_mtime
    except OSError:
        before = 0.0
    while not stop.is_set():
        try:
            now = os.stat(core).st_mtime
        except OSError:
            now = before
        if now != before:
            before = now
            if args.mode == "noswap":
                # the core is never picked up: what a disabled plugin looks like
                pass
            else:
                time.sleep(0.2)
                write_json(
                    os.path.join(args.config_dir, "selftest", "core-loaded.json"),
                    {"build_id": args.build_id, "commit": args.commit,
                     "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
                )
        stop.wait(0.2)


def run_selftest(args, suites):
    """`/term selftest` in the game: a new complete report a moment later."""
    time.sleep(0.3)
    build = args.build_id if args.mode != "stale" else args.build_id + "-old"
    report = selftest_report(build, args.commit, str(uuid.uuid4())[:8],
                             failing=args.mode == "fail")
    report["suites"] = suites
    write_json(os.path.join(args.config_dir, "selftest", "latest.json"), report)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "mock-xivmcp/1"

    def log_message(self, fmt, *a):  # one tidy line per request, never the token
        sys.stderr.write("mock-xivmcp: %s\n" % (fmt % a))

    # -- plumbing ---------------------------------------------------------
    def _send(self, code, body=None, headers=()):
        raw = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        if raw:
            self.wfile.write(raw)

    def _authed(self):
        want = "Bearer " + STATE["args"].token
        if self.headers.get("Authorization") != want:
            self._send(401, {"error": "unauthorized"})
            return False
        return True

    def do_DELETE(self):  # noqa: N802  (the session teardown ingame.sh does)
        if not self._authed():
            return
        STATE["session"] = None
        self._send(200, {"ok": True})

    def do_POST(self):  # noqa: N802
        args = STATE["args"]
        if not self._authed():
            return
        length = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._send(400, {"error": "bad json"})
            return
        method = req.get("method")
        rid = req.get("id")

        if method == "initialize":
            STATE["session"] = uuid.uuid4().hex
            self._send(200, {
                "jsonrpc": "2.0", "id": rid,
                "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                           "serverInfo": {"name": "XivMcp", "version": "0.0.0-mock"}},
            }, headers=[("Mcp-Session-Id", STATE["session"])])
            return

        # everything else needs the session initialize handed out
        if self.headers.get("Mcp-Session-Id") != STATE.get("session"):
            self._send(400, {"error": "missing or stale Mcp-Session-Id"})
            return

        if method == "notifications/initialized":
            self._send(200, {"jsonrpc": "2.0", "id": rid, "result": {}})
            return

        if method != "tools/call":
            self._send(200, {"jsonrpc": "2.0", "id": rid,
                             "error": {"code": -32601, "message": "no such method"}})
            return

        p = req.get("params") or {}
        name = p.get("name")
        a = p.get("arguments") or {}

        def ok(value, structured=True):
            res = {"content": [{"type": "text", "text": json.dumps(value)}], "isError": False}
            if structured and isinstance(value, dict):
                res["structuredContent"] = value
            self._send(200, {"jsonrpc": "2.0", "id": rid, "result": res})

        def err(text):
            self._send(200, {"jsonrpc": "2.0", "id": rid,
                             "result": {"content": [{"type": "text", "text": text}],
                                        "isError": True}})

        if name == "get_player":
            if args.mode == "noplayer":
                err("no character is logged in")
            else:
                ok({"name": "Mock Character", "world": "Mock"})
        elif name == "get_dalamud_info":
            ok({"dalamudVersion": "0.0.0.0", "gameVersion": "0000.00.00.0000.0000"})
        elif name == "list_plugins":
            ok({"plugins": [
                {"internalName": "GhosttyDalamud", "version": "0.0.0-mock", "isLoaded": True},
                {"internalName": "XivMcp", "version": "0.0.0-mock", "isLoaded": True},
                {"internalName": "SomethingElse", "version": "1.0", "isLoaded": True},
            ]}, structured=True)
        elif name == "execute_command":
            cmd = str(a.get("command", ""))
            # exactly the allowlist the real ghostty-ci client is given
            head = cmd.split(" ")[:2]
            if head != ["/term", "selftest"]:
                err("command not allowed for this client: %r" % cmd)
                return
            suites = cmd[len("/term selftest"):].strip() or "all"
            threading.Thread(target=run_selftest, args=(args, suites), daemon=True).start()
            ok({"ran": cmd}, structured=False)
        else:
            err("no such tool: %s" % name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plugin-dir", required=True)
    ap.add_argument("--config-dir", required=True)
    ap.add_argument("--build-id", required=True)
    ap.add_argument("--commit", default="0" * 40)
    ap.add_argument("--token", default="mock-token")
    ap.add_argument("--mode", default="pass",
                    choices=["pass", "fail", "nogame", "noplayer", "noswap", "stale"])
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--port-file")
    ap.add_argument("--ready-file")
    args = ap.parse_args()
    STATE["args"] = args
    STATE["session"] = None

    if args.mode == "nogame":
        # nothing listens: what ingame.sh sees when the game is not running
        if args.port_file:
            with open(args.port_file, "w", encoding="utf-8") as f:
                f.write("1\n")  # port 1: connection refused
        if args.ready_file:
            open(args.ready_file, "w", encoding="utf-8").close()
        while True:
            time.sleep(3600)

    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    port = httpd.server_address[1]
    stop = threading.Event()
    threading.Thread(target=loader_thread, args=(args, stop), daemon=True).start()
    if args.port_file:
        with open(args.port_file, "w", encoding="utf-8") as f:
            f.write("%d\n" % port)
    sys.stderr.write("mock-xivmcp: listening on 127.0.0.1:%d mode=%s\n" % (port, args.mode))
    sys.stderr.flush()
    if args.ready_file:
        open(args.ready_file, "w", encoding="utf-8").close()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()


if __name__ == "__main__":
    main()
