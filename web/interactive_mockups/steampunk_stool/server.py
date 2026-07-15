#!/usr/bin/env python3
"""server.py -- the ONE process behind the interactive 3D steampunk-stool
mockup page (dropped-work-recovery item 3, Liam msg 1526751917060128809).

Two jobs, one process:

  1. **Demo-window consumer** for Wavelet's real ``param_channel`` /
     ``ws://`` substrate (``projection/graph/param_channel_node.py`` +
     ``projection/transport/ws_relay_server.py``, merged PR #910). Runs the
     ``ws://`` relay hub AND a ``param_channel`` client that drains it
     (last-write-wins, exactly ``param_channel_latest()``'s documented
     usage), regenerating the REAL proc3d stool Assembly
     (``tools/stool_tunable.py`` -- reuses Wavelet's proc3d primitives, does
     not fork them) and re-exporting it to a real ``.glb`` on every param
     change via the CANONICAL proc3d exporter
     (``Alethea-cc/tools/proc3d/glb_export.py``, PR #934 -- landed
     concurrently with this page; this page no longer carries its own GLB
     writer, see the import block below).
  2. **Static file server** for this page's own ``index.html`` / ``tuner.html``
     / ``static/*`` / the generated ``.glb`` + ``status.json``, so the whole
     thing is one ``py server.py`` away from a working page in a browser.

Any browser tab -- the embedded in-tab panel OR a genuine ``window.open()``
popout -- talks to the SAME ``ws://`` room with the SAME
``{"param","value","ts"}`` wire message ``param_channel_node.py`` already
defines; this script does not invent a second protocol.

Usage (this host resolves bare ``python`` to a non-functional Windows Store
stub -- always use ``py``):
    py server.py
    py server.py --http-port 8791 --ws-port 8790

schema-version: 1.0.0
"""
from __future__ import annotations

import argparse
import http.server
import json
import os
import socketserver
import sys
import threading
import time
from pathlib import Path
from typing import Any, Dict

BASE_DIR = Path(__file__).resolve().parent
TOOLS_DIR = BASE_DIR / "tools"
GENERATED_DIR = BASE_DIR / "generated"
CONFIG_PATH = GENERATED_DIR / "config.json"
STATUS_PATH = GENERATED_DIR / "status.json"
LIVE_GLB_PATH = GENERATED_DIR / "live_stool.glb"

if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))


def _find_wavelet_root() -> Path:
    """Same resolution strategy as ``tools/stool_tunable.py``'s
    ``_find_wavelet_proc3d_dir`` (kept as a separate, intentionally-duplicated
    ~10-line lookup here rather than a shared import, since this script needs
    the WAVELET ROOT for ``projection.*`` while stool_tunable.py needs the
    proc3d subdirectory specifically -- two small distinct lookups, not one
    primitive worth factoring/coupling across the two tools)."""
    candidates = []
    env = os.environ.get("WAVELET_ROOT")
    if env:
        candidates.append(Path(env))
    for ancestor in BASE_DIR.parents:
        if ancestor.name == "repos":
            candidates.append(ancestor.parent)
            break
    candidates.append(Path("G:/Wavelet"))
    for root in candidates:
        if (root / "projection" / "transport" / "ws_relay_server.py").is_file():
            return root
    raise RuntimeError(
        "could not locate the Wavelet checkout root (need projection/transport/"
        f"ws_relay_server.py under it) -- checked {[str(c) for c in candidates]}; "
        "set WAVELET_ROOT explicitly if this host's layout differs"
    )


_WAVELET_ROOT = _find_wavelet_root()
if str(_WAVELET_ROOT) not in sys.path:
    sys.path.insert(0, str(_WAVELET_ROOT))

from projection.transport.ws_relay_server import start_relay_server  # noqa: E402
from projection.graph.param_channel_node import (  # noqa: E402
    param_channel_build,
    param_channel_latest,
)

import stool_tunable  # noqa: E402  (this page's own tools/, added to sys.path above;
                       # also puts Wavelet's Alethea-cc/tools/proc3d/ on sys.path)

# The CANONICAL proc3d GLB exporter (Alethea-cc/tools/proc3d/glb_export.py,
# PR #934, DQ-36840cea -- merged 2026-07-15, concurrently with this page's own
# build). This page used to carry its OWN hand-rolled GLB writer
# (tools/glb_export.py, since removed) written before that PR landed; once the
# real one shipped upstream, keeping a duplicate would violate "reuse, don't
# rebuild" -- this now imports the real thing instead. proc3d/ is already on
# sys.path via stool_tunable's own import above (same directory glb_export.py
# lives in).
from glb_export import assembly_to_glb  # noqa: E402


class RegenServer:
    """Owns the live param state, the regen loop, and the relay handle."""

    def __init__(self, ws_host: str, ws_port: int, room: str, poll_interval: float = 0.12) -> None:
        self.room = room
        self.poll_interval = poll_interval
        self.relay = start_relay_server(ws_host, ws_port)
        self.room_uri = f"{self.relay.uri_base}/{room}"
        self._consumer_state = param_channel_build({"uri": self.room_uri})
        self.params: Dict[str, float] = stool_tunable.default_params()
        self.version = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True, name="stool-regen-loop")
        GENERATED_DIR.mkdir(parents=True, exist_ok=True)

    # -- regeneration -------------------------------------------------------
    def regenerate(self) -> None:
        asm = stool_tunable.build_stool(self.params)
        data = assembly_to_glb(asm)
        GENERATED_DIR.mkdir(parents=True, exist_ok=True)
        tmp = LIVE_GLB_PATH.with_suffix(LIVE_GLB_PATH.suffix + ".tmp")
        tmp.write_bytes(data)
        tmp.replace(LIVE_GLB_PATH)  # atomic-ish swap so the http poller never reads a half-written file
        self.version += 1
        self._write_status()

    def _write_status(self) -> None:
        STATUS_PATH.write_text(
            json.dumps(
                {
                    "version": self.version,
                    "params": self.params,
                    "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                },
                indent=2,
            ),
            encoding="utf-8",
        )

    def write_config(self, http_port: int) -> None:
        CONFIG_PATH.write_text(
            json.dumps(
                {
                    "ws_uri": self.room_uri,
                    "room": self.room,
                    "http_port": http_port,
                    "defaults": stool_tunable.DEFAULTS,
                    "ranges": stool_tunable.RANGES,
                },
                indent=2,
            ),
            encoding="utf-8",
        )

    # -- the demo-window drain loop (param_channel_latest, as documented) --
    def _loop(self) -> None:
        while not self._stop.is_set():
            latest = param_channel_latest(self._consumer_state)
            if latest:
                changed = False
                for name, value in latest.items():
                    if name not in self.params:
                        continue
                    try:
                        fv = float(value)
                    except (TypeError, ValueError):
                        continue
                    if self.params[name] != fv:
                        self.params[name] = fv
                        changed = True
                if changed:
                    self.params = stool_tunable.sanitize_params(self.params)
                    self.regenerate()
            self._stop.wait(self.poll_interval)

    def start(self) -> None:
        self.regenerate()  # initial GLB so the page has something to load immediately
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=2.0)
        self.relay.stop()


class _NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    """Static file handler for BASE_DIR, with no-cache on /generated/* so the
    viewer's status/GLB poll never serves a stale cached copy."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, directory=str(BASE_DIR), **kwargs)

    def end_headers(self) -> None:
        if "/generated/" in self.path:
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

    def log_message(self, fmt: str, *args: Any) -> None:  # quieter default logging
        sys.stderr.write("[http] " + (fmt % args) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--http-port", type=int, default=8791)
    ap.add_argument("--ws-port", type=int, default=8790)
    ap.add_argument("--room", default="steampunk-stool")
    args = ap.parse_args()

    regen = RegenServer(args.host, args.ws_port, args.room)
    regen.write_config(args.http_port)
    regen.start()

    httpd = socketserver.ThreadingTCPServer((args.host, args.http_port), _NoCacheHandler)
    httpd.daemon_threads = True

    print(f"param-channel ws relay : {regen.room_uri}")
    print(f"page (viewer)          : http://{args.host}:{args.http_port}/index.html")
    print(f"page (popout tuner)    : http://{args.host}:{args.http_port}/tuner.html")
    print("Ctrl+C to stop\n")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.shutdown()
        regen.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
