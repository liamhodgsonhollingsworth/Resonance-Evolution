"""Entry point — ``python -m tools.workflow_streamlit``.

Forwards to ``streamlit run <this_dir>/app.py`` with sensible defaults
(localhost binding, headless mode off so the browser auto-opens). Any
extra args are passed through to Streamlit unchanged, so
``python -m tools.workflow_streamlit --server.port 8765`` works.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    app_path = Path(__file__).resolve().parent / "app.py"
    # Bias toward auto-open-in-browser for the local launch path; the
    # batch script can override by passing --server.headless true.
    args = [
        sys.executable, "-m", "streamlit", "run", str(app_path),
        "--server.headless=false",
        "--browser.gatherUsageStats=false",
    ]
    args.extend(argv)
    # Ensure the Apeiron repo root is importable from inside the
    # Streamlit subprocess (sys.path manipulation in app.py covers the
    # in-process case; this covers any child the subprocess spawns).
    repo_root = Path(__file__).resolve().parents[2]
    pythonpath = os.environ.get("PYTHONPATH", "")
    if str(repo_root) not in pythonpath.split(os.pathsep):
        os.environ["PYTHONPATH"] = (
            f"{repo_root}{os.pathsep}{pythonpath}" if pythonpath else str(repo_root)
        )
    os.execvp(args[0], args)


if __name__ == "__main__":
    raise SystemExit(main())
