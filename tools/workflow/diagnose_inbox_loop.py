"""Diagnose the Streamlit inbox loop — send N pings, time round-trips.

Usage:
    python -m tools.workflow.diagnose_inbox_loop
    python -m tools.workflow.diagnose_inbox_loop --count 10
    python -m tools.workflow.diagnose_inbox_loop --count 50 --timeout 120

What it does:

1. Reads the current default workflow-mgmt session UUID from
   ``state/workflow/default_workflow_mgmt.txt``.
2. Writes N inbox files into ``Alethea-cc/nodes/``, each addressed to
   that UUID and containing a unique 12-char hex token in the body.
3. Waits up to ``--timeout`` seconds for replies addressed to
   ``diagnose-inbox-loop`` that contain each token.
4. Reports per-ping latency, the set of missed tokens (if any), and
   summary statistics. Exit code 0 if every ping received a reply, 1
   otherwise — so the tool is usable in CI / smoke / cron contexts.

The tool requires the Streamlit workflow surface to be running because
the ``InboxPump`` inside it is what delivers messages to the session's
stdin pipe. If the pump is not running, every ping times out and the
tool exits 1.

Built 2026-05-21 as the stress-test surface for PR Apeiron#57's inbox
loop closure. Keep it — future sessions touching the inbox loop should
re-run this tool as a smoke check before / after their changes.
"""

from __future__ import annotations

import argparse
import os
import re
import secrets
import sys
import time
from pathlib import Path
from typing import List, Optional


# Match `to: diagnose-inbox-loop` ONLY at the start of a line (i.e. inside
# the YAML frontmatter), not in body prose where the same string can
# appear as instructional text. ``re.MULTILINE`` so ``^`` is line-start.
_TO_DIAG_FRONTMATTER_RE = re.compile(
    r"^to:\s+diagnose-inbox-loop\s*$", re.MULTILINE,
)


# We compute these at runtime because the tool can be invoked from any
# cwd. The marker lives under the repo root; the inbox lives in the
# Alethea-cc sibling checkout (or under state/inbox/ if no sibling).


REPO_ROOT = Path(__file__).resolve().parents[2]
MARKER = REPO_ROOT / "state/workflow/default_workflow_mgmt.txt"
ALETHEA_CC_CANDIDATES = (
    Path("C:/Users/Liam/Desktop/Alethea/Alethea-cc/nodes"),
    Path.home() / "Desktop/Alethea/Alethea-cc/nodes",
)


def _find_inbox_dir() -> Path:
    explicit = os.environ.get("ALETHEA_CC_ROOT")
    if explicit:
        p = Path(explicit) / "nodes"
        if p.exists():
            return p
    for p in ALETHEA_CC_CANDIDATES:
        if p.exists():
            return p
    # Fall back to the local state/inbox.
    p = REPO_ROOT / "state" / "inbox"
    if p.exists():
        return p
    raise SystemExit("could not locate an inbox directory")


def _read_default_session(marker: Path) -> str:
    if not marker.exists():
        raise SystemExit(f"no marker at {marker} — is the Streamlit surface running?")
    sid = marker.read_text(encoding="utf-8").strip()
    if not sid:
        raise SystemExit("marker file is empty — Streamlit surface has not spawned the default session yet")
    return sid


def _write_ping(inbox_dir: Path, session_id: str, token: str, idx: int) -> Path:
    ts = time.strftime("%Y%m%d_%H%M%S", time.gmtime())
    fname = f"inbox_msg_{ts}_diag_{idx:03d}_{token[:6]}.md"
    path = inbox_dir / fname
    body = (
        f"---\n"
        f"to: {session_id}\n"
        f"from: diagnose-inbox-loop\n"
        f"kind: chat\n"
        f"summary: \"Inbox-loop diagnostic ping {idx} (token {token})\"\n"
        f"---\n\n"
        f"This is a diagnostic ping from tools/workflow/diagnose_inbox_loop.py.\n"
        f"\n"
        f"Please reply by writing an inbox file with:\n"
        f"  to: diagnose-inbox-loop\n"
        f"  from: {session_id}\n"
        f"  kind: chat\n"
        f"  summary: \"diag-reply {token}\"\n"
        f"and a body containing the literal token below.\n"
        f"\n"
        f"Token: {token}\n"
        f"\n"
        f"Reply briefly; the body just needs to contain {token} verbatim.\n"
    )
    path.write_text(body, encoding="utf-8")
    return path


def _find_reply(
    inbox_dir: Path,
    token: str,
    since_ts: float,
    exclude_paths: Optional[set] = None,
) -> Optional[Path]:
    """Return the first inbox file whose frontmatter `to:` is
    `diagnose-inbox-loop` AND whose body contains the token.

    The frontmatter check is critical: pings written by THIS tool contain
    the literal string ``to: diagnose-inbox-loop`` in their instructional
    body (as part of the reply template). A naive substring search would
    self-match. ``_TO_DIAG_FRONTMATTER_RE`` anchors at line-start so only
    the frontmatter line (no leading whitespace) matches. ``exclude_paths``
    is a defense-in-depth: explicitly skip the ping files we just wrote.
    """
    exclude_paths = exclude_paths or set()
    for path in inbox_dir.glob("inbox_msg_*.md"):
        try:
            if path in exclude_paths:
                continue
            if path.stat().st_mtime < since_ts:
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            if not _TO_DIAG_FRONTMATTER_RE.search(text):
                continue
            if token in text:
                return path
        except Exception:
            continue
    return None


def run(count: int, timeout: float, poll_interval: float, gap: float) -> int:
    inbox_dir = _find_inbox_dir()
    sid = _read_default_session(MARKER)
    print(f"[diag] default session = {sid}")
    print(f"[diag] inbox dir       = {inbox_dir}")
    print(f"[diag] sending {count} ping(s), waiting up to {timeout}s each\n")

    pings: List[dict] = []
    write_start = time.time()
    for i in range(count):
        token = secrets.token_hex(6)
        sent_at = time.time()
        path = _write_ping(inbox_dir, sid, token, i)
        pings.append({
            "i": i,
            "token": token,
            "path": path,
            "sent_at": sent_at,
            "reply": None,
            "elapsed": None,
        })
        if gap > 0:
            time.sleep(gap)
    write_elapsed = time.time() - write_start
    print(f"[diag] {count} pings written in {write_elapsed:.2f}s\n")

    ping_paths = {p["path"] for p in pings}
    deadline = time.time() + timeout
    remaining = list(pings)
    while remaining and time.time() < deadline:
        new_remaining = []
        for p in remaining:
            reply = _find_reply(
                inbox_dir, p["token"], p["sent_at"] - 1.0,
                exclude_paths=ping_paths,
            )
            if reply is not None:
                p["reply"] = reply
                p["elapsed"] = time.time() - p["sent_at"]
                print(
                    f"  ping {p['i']+1:>3}/{count}  OK   in {p['elapsed']:5.1f}s  "
                    f"token={p['token']}  reply={reply.name}"
                )
            else:
                new_remaining.append(p)
        remaining = new_remaining
        if remaining:
            time.sleep(poll_interval)

    for p in remaining:
        p["elapsed"] = time.time() - p["sent_at"]
        print(
            f"  ping {p['i']+1:>3}/{count}  MISS  >{p['elapsed']:5.1f}s  "
            f"token={p['token']}"
        )

    ok = [p for p in pings if p["reply"] is not None]
    miss = [p for p in pings if p["reply"] is None]

    print()
    if ok:
        lats = sorted(p["elapsed"] for p in ok)
        avg = sum(lats) / len(lats)
        mn, mx = lats[0], lats[-1]
        med = lats[len(lats) // 2]
        print(
            f"[diag] {len(ok)}/{count} OK   "
            f"min={mn:.1f}s  med={med:.1f}s  avg={avg:.1f}s  max={mx:.1f}s"
        )
    if miss:
        print(f"[diag] {len(miss)}/{count} MISSED — tokens:")
        for p in miss:
            print(f"        {p['token']}")
        return 1
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(
        description="Diagnose the Streamlit inbox loop by timing N pings.",
    )
    p.add_argument("--count", type=int, default=1, help="number of pings (default 1)")
    p.add_argument(
        "--timeout", type=float, default=60.0,
        help="wall-clock timeout in seconds for all pings combined (default 60)",
    )
    p.add_argument(
        "--poll", type=float, default=0.5,
        help="reply-polling interval in seconds (default 0.5)",
    )
    p.add_argument(
        "--gap", type=float, default=0.1,
        help="pause between writing successive pings (default 0.1s)",
    )
    args = p.parse_args(argv)
    return run(args.count, args.timeout, args.poll, args.gap)


if __name__ == "__main__":
    sys.exit(main())
