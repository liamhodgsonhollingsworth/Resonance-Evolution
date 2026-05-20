"""
Per-node edit history — SPEC-076 (History button derived-view).

Append-only NDJSON at ``<root>/state/node_history/<node-id>.jsonl``;
each row is one engine-mutation event written by the engine's mutation
surface (spawn / set_param / connect / disconnect / archive / restore).

Row schema (forward-compatible — readers ignore unknown keys):

    {
        "ts": "2026-05-20T14:33:12Z",  # UTC, second precision
        "session_id": "<session-id-or-empty>",
        "kind": "spawn|set_param|connect|disconnect|archive|restore|...",
        "payload": { ... event-specific fields ... },
        "summary": "title: X -> Y"     # optional one-line
    }

Composes with:

- SPEC-079 active-sessions: ``session_id`` is the caller's current
  session id when one is registered on the engine; otherwise empty.
- SPEC-026 monotonic-information: this file is append-only. A future
  checkpoint+tail compaction may rewrite it but never deletes rows
  without preserving the checkpoint.
- SPEC-067 derived views: the History view is a
  ``ViewSpec(kind="dynamic")`` whose items-provider reads
  :func:`read_node_history` for the focused node-id.

Resilience: a half-written row (crash mid-write) leaves a malformed
last line. The reader skips unparseable lines and logs to
``engine.errors`` when given an engine handle. The lost row is at
worst the in-flight event; the next mutation appends a fresh complete
row.
"""

from __future__ import annotations

import datetime as _dt
import json
import os
from pathlib import Path
from typing import Any, Dict, List, Optional


def history_dir(root: Path) -> Path:
    """Return ``<root>/state/node_history``, creating it if missing.

    The env var ``APEIRON_NODE_HISTORY_ROOT_OVERRIDE`` (test-only)
    redirects every history write to ``<override>/state/node_history``
    so the test suite can run without polluting the repo's
    ``state/node_history`` directory.
    """
    override = os.environ.get("APEIRON_NODE_HISTORY_ROOT_OVERRIDE", "")
    base = Path(override) if override else Path(root)
    target = base / "state" / "node_history"
    target.mkdir(parents=True, exist_ok=True)
    return target


def history_path(root: Path, node_id: str) -> Path:
    """The on-disk path for a given node-id's history file.

    Node-ids are used as filenames so the layout is fully derivable
    from the id. The caller is expected to have already validated the
    id (engine spawn rejects unsafe characters via the scene loader).
    For safety we still reject ``..`` segments — a malicious paste
    must not write outside the history directory.
    """
    safe = str(node_id).replace(os.sep, "_")
    if "/" in safe or ".." in safe or safe.startswith("."):
        raise ValueError(f"unsafe node id for history file: {node_id!r}")
    return history_dir(root) / f"{safe}.jsonl"


def _utc_now_iso() -> str:
    """ISO-8601 UTC timestamp, second precision, Z suffix."""
    now = _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0)
    return now.isoformat().replace("+00:00", "Z")


def append_history_row(
    root: Path,
    node_id: str,
    kind: str,
    payload: Optional[Dict[str, Any]] = None,
    summary: str = "",
    session_id: str = "",
    ts: Optional[str] = None,
) -> Dict[str, Any]:
    """Append one event row to ``<root>/state/node_history/<node-id>.jsonl``.

    Returns the row dict (with the resolved ``ts`` field) so callers
    can mirror it into in-memory queues without re-reading the file.

    Resilience: an OSError on write is swallowed silently — history
    is a diagnostic surface; losing a row must not crash the engine
    mutation that triggered it. The next write retries cleanly.
    """
    if not node_id:
        return {}
    row: Dict[str, Any] = {
        "ts": ts or _utc_now_iso(),
        "session_id": str(session_id or ""),
        "kind": str(kind),
        "payload": dict(payload or {}),
    }
    if summary:
        row["summary"] = str(summary)
    try:
        path = history_path(root, node_id)
    except ValueError:
        return row
    try:
        line = json.dumps(row, ensure_ascii=False, separators=(",", ":"))
    except (TypeError, ValueError):
        # Payload not JSON-serialisable. Drop to a degraded shape that
        # preserves the kind + timestamp so the row still appears in
        # the history view.
        safe_row = {
            "ts": row["ts"],
            "session_id": row["session_id"],
            "kind": row["kind"],
            "payload": {"__serialization_error__": True},
        }
        if summary:
            safe_row["summary"] = row.get("summary", "")
        line = json.dumps(safe_row, ensure_ascii=False, separators=(",", ":"))
        row = safe_row
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line)
            fh.write("\n")
    except OSError:
        # Diagnostic surface — swallow to keep the engine mutation safe.
        return row
    return row


def read_node_history(
    root: Path,
    node_id: str,
    newest_first: bool = True,
    engine: Any = None,
) -> List[Dict[str, Any]]:
    """Read every parseable row from a node's history file.

    Returns ``[]`` when the file does not exist (a fresh node hasn't
    written history yet). Skips malformed lines but does not raise —
    if an ``engine`` handle is supplied, the malformed lines are
    logged to ``engine.errors``.

    The list is returned newest-first by default so the History view
    can render most-recent edits at the top without an extra sort
    step.
    """
    try:
        path = history_path(root, node_id)
    except ValueError:
        return []
    if not path.exists():
        return []
    rows: List[Dict[str, Any]] = []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for lineno, raw in enumerate(fh, start=1):
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    rows.append(json.loads(raw))
                except json.JSONDecodeError as exc:
                    if engine is not None and hasattr(engine, "errors"):
                        engine.errors.append(
                            f"read_node_history({node_id}, line {lineno}): "
                            f"skipping malformed row: {exc}"
                        )
                    continue
    except OSError:
        return []
    if newest_first:
        rows.reverse()
    return rows


def clear_node_history(root: Path, node_id: str) -> bool:
    """Remove a node's history file. Used by tests; not by production.

    Returns True if the file was deleted, False if it didn't exist.
    Production callers should treat history as append-only — there is
    no archive-on-delete primitive yet; that lives behind SPEC-026's
    "restructure without forgetting" rule.
    """
    try:
        path = history_path(root, node_id)
    except ValueError:
        return False
    if not path.exists():
        return False
    try:
        path.unlink()
    except OSError:
        return False
    return True
