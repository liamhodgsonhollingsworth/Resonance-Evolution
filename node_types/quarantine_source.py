"""
QuarantineSource — emits maintainer-inbox quarantined messages with
scan annotations as panel items.

Per-item actions:

- ``expand`` — handled by ListRenderer; shows full body + scan findings.
- ``promote-sender`` — adds the sender to the sender-trust-set so future
  messages from this sender route to the main inbox (SPEC-057).
- ``delete`` — removes the quarantined message file from disk.

The action handlers are bound at precompute time and stored alongside
items in ``engine.cache[node_id]`` under ``_action_handlers``. The
ListRenderer's ``handle_action`` delegates verbs other than
``expand``/``collapse`` to this dict. The bind-at-precompute shape means
the handlers always operate against the latest state-dir/user configured
on the node — a parameter change re-binds on the next precompute.

Composes with SPEC-057 (sender filter) + SPEC-058 (scan). The render
gate (SPEC-054) protects the engine itself; this source protects the
maintainer's reading surface.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any, Dict, List

from engine.node import Channels, EmitContext, Manifest, View


_SEVERITY_TO_STATUS = {"HIGH": "alert", "MEDIUM": "warn", "LOW": "ok"}


def manifest() -> Manifest:
    return Manifest(
        name="QuarantineSource",
        version="1.0",
        renderer_id="raster",
        inputs={
            "root": "string",
            "state_dir": "string",
            "user": "string",
            "alethea_cc_root": "string",
            "max_items": "int",
        },
        outputs={"items": "list_of_dict"},
        description=(
            "Quarantined inbox messages with scan annotations. "
            "Per-item actions: expand, promote-sender, delete. "
            "max_items bounds the per-precompute scan cost — messages "
            "beyond the limit are listed by Inbox but not scanned."
        ),
    )


def build(params):
    return {
        "root": str(params.get("root", ".")),
        "state_dir": str(params.get("state_dir", "")),
        "user": str(params.get("user", "")),
        # "" → auto-detect, "none" → skip the shared dir entirely
        # (tests pass "none" so the panel scopes to its tmp_path state).
        "alethea_cc_root": str(params.get("alethea_cc_root", "")),
        # Bound scan cost so the workflow surface opens fast even when
        # the maintainer has hundreds of accumulated quarantined
        # messages. 50 covers a backlog at-a-glance; the rest still
        # exist in the filesystem and can be inspected via direct
        # Inbox calls or by raising this number on the panel.
        "max_items": int(params.get("max_items", 50)),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    return []


def precompute_hook(state, engine, node):
    from tools.workflow.inbox import Inbox
    from tools.workflow.quarantine import scan_message
    from tools.workflow.trust import sender_trust_set

    root = Path(state["root"])
    state_dir = (
        Path(state["state_dir"])
        if state["state_dir"]
        else root / "state" / "workflow"
    )
    user = state["user"] or None

    try:
        ts = sender_trust_set(root, user)
        alethea_cc_kwarg = _resolve_alethea_cc_kwarg(state["alethea_cc_root"])
        inbox = Inbox(state_dir=state_dir, sender_trust=ts, **alethea_cc_kwarg)
        quarantined = inbox.list_quarantine()
    except Exception as e:
        return {"items": [], "error": f"QuarantineSource: {e}"}

    # Bound the scan cost. list_quarantine returns oldest-first; trim to
    # the most-recent ``max_items`` so a backlog of hundreds doesn't
    # explode precompute time at scene open.
    max_items = max(1, int(state.get("max_items", 50)))
    if len(quarantined) > max_items:
        quarantined = quarantined[-max_items:]

    items: List[Dict[str, Any]] = []
    for msg in quarantined:
        try:
            report = scan_message(msg)
        except Exception as e:
            items.append(_error_item(msg, f"scan failed: {e}"))
            continue
        status = _SEVERITY_TO_STATUS.get(report.overall_severity, "ok")
        finding_lines = []
        for f in report.findings[:6]:
            finding_lines.append(f"[{f.severity}] {f.category}: {f.detail}")
        if len(report.findings) > 6:
            finding_lines.append(f"… {len(report.findings) - 6} more findings")
        if not finding_lines:
            finding_lines = ["(no scan findings)"]
        body = (
            f"From: {msg.sender}\n"
            f"To: {msg.to}\n"
            f"Kind: {msg.kind}\n"
            f"File: {msg.path.name}\n"
            f"\nScan ({report.overall_severity}, "
            f"anomaly={report.anomaly_score:.2f}):\n"
            + "\n".join("  " + line for line in finding_lines)
            + f"\n\nSummary: {msg.summary}\n\nBody:\n{(msg.body or '')[:2000]}"
        )
        title = _truncate(f"{msg.sender}: {msg.summary or '(no summary)'}", 80)
        items.append({
            "id": _msg_id(msg),
            "title": title,
            "body": body,
            "status": status,
            "meta": {
                "sender": msg.sender,
                "kind": msg.kind,
                "severity": report.overall_severity,
                "anomaly_score": round(report.anomaly_score, 3),
                "findings": len(report.findings),
                "path": str(msg.path),
            },
            "actions": ["expand", "promote-sender", "delete"],
        })

    handlers = _build_action_handlers(root, user or "")
    return {"items": items, "error": None, "_action_handlers": handlers}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    cache = ctx.engine.cache.get(ctx.node.id, {}) or {}
    return {
        "items": cache.get("items", []),
        "source_error": cache.get("error"),
    }


def describe(state, ctx: EmitContext) -> str:
    cache = ctx.engine.cache.get(ctx.node.id, {}) or {}
    items = cache.get("items", [])
    err = cache.get("error")
    if err:
        return f"QuarantineSource: error — {err}"
    return f"QuarantineSource(root={state['root']!r}, items={len(items)})"


def _msg_id(msg) -> str:
    digest = hashlib.sha256(str(msg.path).encode("utf-8")).hexdigest()[:12]
    return f"qmsg:{digest}"


def _resolve_alethea_cc_kwarg(value: str) -> Dict[str, Any]:
    """Translate the scene-JSON-friendly string into the Inbox kwarg.

    - "" → auto-detect (omit the kwarg entirely; Inbox uses its
      ``_DETECT`` sentinel).
    - "none" / "skip" → pass ``None`` so the shared dir is skipped.
    - anything else → use the path verbatim.
    """
    s = (value or "").strip().lower()
    if s == "":
        return {}
    if s in ("none", "skip", "off"):
        return {"alethea_cc_root": None}
    return {"alethea_cc_root": Path(value)}


def _truncate(s: str, n: int) -> str:
    if len(s) <= n:
        return s
    return s[: n - 1] + "…"


def _error_item(msg, err: str) -> Dict[str, Any]:
    return {
        "id": _msg_id(msg),
        "title": f"{msg.sender}: (scan error)",
        "body": err,
        "status": "alert",
        "meta": {
            "sender": msg.sender,
            "kind": msg.kind,
            "severity": "HIGH",
            "anomaly_score": 0.0,
            "findings": 0,
            "path": str(msg.path),
        },
        "actions": ["expand", "delete"],
    }


def _build_action_handlers(root: Path, user: str):
    from tools.workflow.inbox import _parse_message
    from tools.workflow.quarantine import quarantine_delete, quarantine_promote_sender
    from tools.workflow.trust import sender_trust_set

    def _re_resolve(item):
        path_str = (item or {}).get("meta", {}).get("path")
        if not path_str:
            return None
        path = Path(path_str)
        if not path.exists():
            return None
        try:
            return _parse_message(path)
        except Exception:
            return None

    def _promote(payload, engine, node):
        item = payload.get("item") or {}
        msg = _re_resolve(item)
        if msg is None:
            return {"recent_action": ("promote-sender", "<gone>"), "expanded_item": None}
        ts = sender_trust_set(root, user or None)
        quarantine_promote_sender(msg, ts)
        engine.precompute()
        return {
            "recent_action": ("promote-sender", msg.sender),
            "expanded_item": None,
        }

    def _delete(payload, engine, node):
        item = payload.get("item") or {}
        msg = _re_resolve(item)
        if msg is None:
            return {"recent_action": ("delete", "<gone>"), "expanded_item": None}
        quarantine_delete(msg)
        engine.precompute()
        return {
            "recent_action": ("delete", item.get("id")),
            "expanded_item": None,
        }

    return {"promote-sender": _promote, "delete": _delete}
