#!/usr/bin/env python3
"""scene_bridge — the Claude <-> running-game live bridge (HTTP relay).

The running Godot game watches a small set of files in `godot/live/`. This bridge
exposes those files over HTTP so a remote caller (a Claude Code session, the chat
relay, a browser) can drive the live game without touching the filesystem directly:

  POST /api/scene/load        body = an arrangement (JSON)  -> writes live/arrangement.json
                              (the running game hotloads it; no restart)
  GET  /api/scene/get         -> the current arrangement JSON
  POST /api/scene/screenshot  -> asks the running game for a fresh frame, waits for it,
                              then reports it is ready (read it via /api/scene/shot)
  GET  /api/scene/shot        -> the latest screenshot (image/png)
  GET  /api/scene/status      -> { ok, has_arrangement, has_shot, shot_mtime }

It is intentionally tiny, dependency-free (stdlib only), and self-contained — a
portable plugin. It does NOT edit the big shared terminal_bridge.py; the same handlers
can be mounted there later if a single origin is wanted.

Run:  python godot/bridge/scene_bridge.py [--port 8210] [--live-dir <path>]
"""

import argparse
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LIVE_DIR = ""


def _p(name: str) -> str:
    return os.path.join(LIVE_DIR, name)


def _atomic_write(path: str, data: bytes) -> None:
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):  # quiet
        pass

    def _send(self, code: int, body: bytes, ctype: str = "application/json") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, obj) -> None:
        self._send(code, json.dumps(obj).encode("utf-8"))

    def do_OPTIONS(self):
        self._send(204, b"")

    def do_GET(self):
        if self.path == "/api/scene/get":
            path = _p("arrangement.json")
            if not os.path.exists(path):
                return self._json(404, {"ok": False, "error": "no arrangement yet"})
            with open(path, "rb") as f:
                return self._send(200, f.read())
        if self.path == "/api/scene/shot":
            path = _p("shot.png")
            if not os.path.exists(path):
                return self._json(404, {"ok": False, "error": "no screenshot yet"})
            with open(path, "rb") as f:
                return self._send(200, f.read(), "image/png")
        if self.path == "/api/scene/status":
            shot = _p("shot.png")
            return self._json(200, {
                "ok": True,
                "has_arrangement": os.path.exists(_p("arrangement.json")),
                "has_shot": os.path.exists(shot),
                "shot_mtime": os.path.getmtime(shot) if os.path.exists(shot) else 0,
            })
        return self._json(404, {"ok": False, "error": "unknown route"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        if self.path == "/api/scene/load":
            try:
                obj = json.loads(body or b"{}")
            except json.JSONDecodeError as e:
                return self._json(400, {"ok": False, "error": "invalid JSON: %s" % e})
            # pretty-print so the on-disk arrangement stays human-readable / diffable
            _atomic_write(_p("arrangement.json"),
                          json.dumps(obj, indent="\t").encode("utf-8"))
            return self._json(200, {"ok": True, "bytes": len(body)})
        if self.path == "/api/scene/screenshot":
            shot = _p("shot.png")
            before = os.path.getmtime(shot) if os.path.exists(shot) else 0
            _atomic_write(_p("shot_request.txt"), str(time.time_ns()).encode("utf-8"))
            # wait (up to ~4s) for the running game to produce a fresh frame
            deadline = time.time() + 4.0
            ready = False
            while time.time() < deadline:
                if os.path.exists(shot) and os.path.getmtime(shot) > before:
                    ready = True
                    break
                time.sleep(0.05)
            return self._json(200 if ready else 202,
                              {"ok": True, "ready": ready,
                               "note": "read /api/scene/shot" if ready
                               else "requested; game may not be running"})
        return self._json(404, {"ok": False, "error": "unknown route"})


def main():
    global LIVE_DIR
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("SCENE_BRIDGE_PORT", 8210)))
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--live-dir", default=os.path.normpath(os.path.join(here, "..", "live")))
    args = ap.parse_args()
    LIVE_DIR = args.live_dir
    os.makedirs(LIVE_DIR, exist_ok=True)
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    print("scene_bridge on http://%s:%d  live-dir=%s" % (args.host, args.port, LIVE_DIR), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
