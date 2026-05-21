"""Entry point — ``python -m tools.workflow_streamlit``.

Spawns ``streamlit run app.py`` as a CHILD subprocess and stays
attached to it. The parent process (this script) lives as long as
streamlit lives, so the cmd window the desktop shortcut opens stays
present and shows streamlit's stdout — including every command
dispatch (``[dispatch ...]`` lines from ``command_registry.run``).
That terminal window IS the "desktop terminal" surface the maintainer
asked for: it shows the non-readable parsing side of every interaction
that the in-page terminal renders as a readable CLI command.

v1 used ``os.execvp`` which on Windows replaced the current Python
process with streamlit but lost stdout/stderr wiring back to the cmd
window — the program appeared to never open. v2 uses
``subprocess.run`` which is reliable on every platform.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    here = Path(__file__).resolve().parent
    app_path = here / "app.py"
    repo_root = here.parents[1]

    env = os.environ.copy()
    pythonpath = env.get("PYTHONPATH", "")
    if str(repo_root) not in pythonpath.split(os.pathsep):
        env["PYTHONPATH"] = (
            f"{repo_root}{os.pathsep}{pythonpath}" if pythonpath else str(repo_root)
        )
    # Stream stdout unbuffered so the cmd window updates live.
    env.setdefault("PYTHONUNBUFFERED", "1")

    print("[apeiron] booting Streamlit workflow surface...", flush=True)
    print(f"[apeiron] repo root: {repo_root}", flush=True)
    print(f"[apeiron] app:       {app_path}", flush=True)
    print("[apeiron] this cmd window IS the desktop terminal -- every dispatched")
    print("[apeiron] command prints here; keep it open while you use the page.",
          flush=True)
    print("", flush=True)

    args = [
        sys.executable, "-m", "streamlit", "run", str(app_path),
        "--server.port=8501",
        "--server.headless=false",
        "--browser.gatherUsageStats=false",
    ]
    args.extend(argv)

    try:
        proc = subprocess.Popen(args, env=env)
    except FileNotFoundError as exc:
        print(f"[apeiron] could not launch streamlit: {exc}", file=sys.stderr)
        print("[apeiron] is streamlit installed? `pip install streamlit`",
              file=sys.stderr)
        return 2

    try:
        return proc.wait()
    except KeyboardInterrupt:
        print("[apeiron] received Ctrl+C -- shutting down streamlit...", flush=True)
        try:
            proc.send_signal(signal.SIGINT)
        except Exception:
            proc.terminate()
        try:
            return proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            return 130


if __name__ == "__main__":
    raise SystemExit(main())
