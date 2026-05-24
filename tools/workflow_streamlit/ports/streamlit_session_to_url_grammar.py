"""streamlit_session_to_url_grammar — port-node implementation.

Per brief 02 commit 6 (Decision B5, SPEC-089) — the first of three
Streamlit-to-domain port-nodes.

Contract:
    translate({"session_state": dict, "current_panel": str}) -> {
        "renderer_id": str,
        "content_node_ids": list[str],
        "query": dict,
        "url": str,  # canonical deep-link form
    }

The port maps a Streamlit `st.session_state` snapshot + the currently-
mounted panel name into the canonical URL triple per brief 01 SPEC-083:
`#<renderer_id>/<content_node_id>?<query>`.

Round-trip equality is the load-bearing contract — feeding the produced
URL back through the literal-domain URL parser must produce the same
triple, modulo the canonicalization rules:
  - query keys sorted (deterministic encoding);
  - values URL-encoded;
  - empty/None values dropped from the query.

Pure function. Idempotent: ``translate(translate(x))`` produces the
same URL triple as ``translate(x)`` because the second pass receives
a triple already in canonical form.
"""
from __future__ import annotations

from typing import Any, Dict, List, Optional
from urllib.parse import quote, unquote, urlencode


# Mapping from Streamlit panel name → renderer_id. The default is
# `workflow_continuous_scroll_v1` since that's the canonical MAIN-mount
# panel per brief 02 commit 2. Other mappings are additive.
_PANEL_TO_RENDERER: Dict[str, str] = {
    "workflow-continuous-scroll": "workflow_continuous_scroll_v1",
    "chat": "chat_router_v1",
    "auth": "auth_panel_v1",
    "scene-picker": "scene_picker_v1",
    "session-status": "session_status_v1",
    "terminal": "bottom_terminal_renderer_v1",
}


# Session-state keys that are NOT user-visible (Streamlit internal
# bookkeeping) and should not pollute the URL query.
_INTERNAL_SESSION_KEYS = frozenset({
    "_FormSubmitterDirect",
    "_streamlit_pages_",
    "FormSubmitter",
})


def _to_renderer_id(panel: Optional[str]) -> str:
    """Look up the renderer_id for the panel; fall back to the literal
    panel name when no mapping exists (additive extension surface)."""
    if not panel:
        return "workflow_continuous_scroll_v1"
    return _PANEL_TO_RENDERER.get(panel, panel)


def _extract_content_node_ids(session_state: Dict[str, Any]) -> List[str]:
    """Pull every value out of session_state that looks like a content-
    node id. Convention: id strings start with ``sha256:`` per the
    substrate's content-addressing.
    """
    out: List[str] = []
    if not isinstance(session_state, dict):
        return out
    # Walk top-level + workflow_view_main['positions']-shaped sub-state.
    for key, val in sorted(session_state.items()):
        if key in _INTERNAL_SESSION_KEYS:
            continue
        if isinstance(val, str) and val.startswith("sha256:"):
            out.append(val)
        elif isinstance(val, list):
            for entry in val:
                if isinstance(entry, str) and entry.startswith("sha256:"):
                    out.append(entry)
                elif isinstance(entry, dict):
                    nid = entry.get("node_id") or entry.get("id")
                    if isinstance(nid, str) and nid.startswith("sha256:"):
                        out.append(nid)
    # Deduplicate while preserving first-seen order.
    seen = set()
    unique: List[str] = []
    for nid in out:
        if nid in seen:
            continue
        seen.add(nid)
        unique.append(nid)
    return unique


def _extract_query(session_state: Dict[str, Any]) -> Dict[str, str]:
    """Pull URL-query-relevant fields out of session_state.

    Per the SPEC-083 URL grammar, the query carries:
      - anchor: <content_node_id> (optional, scroll-position)
      - window: <visible,above,below> (optional, sliding-window override)
      - mode: <strict|history_collapsed> (optional, renderer mode)

    Values that are None/empty/internal keys are dropped so the
    URL stays clean.
    """
    out: Dict[str, str] = {}
    if not isinstance(session_state, dict):
        return out
    for k in ("anchor", "window", "mode", "viewport_height", "viewport_width"):
        v = session_state.get(k)
        if v is None or v == "":
            continue
        out[k] = str(v)
    # Surface every workflow-prefixed key for forward-compat extensibility.
    for k, v in session_state.items():
        if not isinstance(k, str) or not k.startswith("query_"):
            continue
        if v is None or v == "":
            continue
        out[k[len("query_"):]] = str(v)
    return dict(sorted(out.items()))


def _format_url(renderer_id: str, content_node_ids: List[str], query: Dict[str, str]) -> str:
    """Build the canonical deep-link URL per SPEC-083.

    Shape: ``#<renderer_id>/<first_content_node_id>?<encoded_query>``.

    When no content-node-id is available the URL drops the trailing
    slash + id segment. When the query is empty the URL drops the
    trailing ``?``.
    """
    base = f"#{renderer_id}"
    if content_node_ids:
        # The first content-node-id is the "primary" target — the
        # canonical deep-link points at it; remaining ids carry over
        # via the query if the surface wants to pre-fetch.
        base += f"/{quote(content_node_ids[0], safe='')}"
        if len(content_node_ids) > 1:
            extras = ",".join(quote(nid, safe="") for nid in content_node_ids[1:])
            query = dict(query)
            query.setdefault("also", extras)
    if query:
        base += "?" + urlencode(sorted(query.items()), quote_via=quote)
    return base


def translate(payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Map a Streamlit session-state + panel name to the canonical URL triple.

    Input shape:
        {"session_state": dict, "current_panel": str}

    Output shape:
        {"renderer_id": str, "content_node_ids": list[str],
         "query": dict, "url": str}

    Pure + idempotent. Empty input produces a default deep-link to the
    workflow_continuous_scroll_v1 renderer with no anchor.
    """
    if payload is None:
        payload = {}
    if not isinstance(payload, dict):
        raise TypeError(
            f"streamlit_session_to_url_grammar.translate: payload must be a dict; "
            f"got {type(payload).__name__}"
        )
    session_state = payload.get("session_state") or {}
    current_panel = payload.get("current_panel") or "workflow-continuous-scroll"

    renderer_id = _to_renderer_id(current_panel)
    content_node_ids = _extract_content_node_ids(session_state)
    query = _extract_query(session_state)
    url = _format_url(renderer_id, content_node_ids, query)

    return {
        "renderer_id": renderer_id,
        "content_node_ids": content_node_ids,
        "query": query,
        "url": url,
    }


def parse_url(url: str) -> Dict[str, Any]:
    """Reverse direction — parse a SPEC-083 URL into the triple.

    Used for round-trip-equality testing per Decision B5 contract.
    Accepts URLs with or without the leading ``#``.
    """
    from urllib.parse import urlparse, parse_qsl

    if not isinstance(url, str):
        raise TypeError(f"parse_url: url must be a string; got {type(url).__name__}")
    s = url.lstrip("#")
    # Split path vs query.
    if "?" in s:
        path, query_str = s.split("?", 1)
    else:
        path, query_str = s, ""
    parts = path.split("/", 1)
    renderer_id = parts[0]
    primary_id = unquote(parts[1]) if len(parts) > 1 and parts[1] else None
    query_pairs = parse_qsl(query_str, keep_blank_values=False)
    query = dict(query_pairs)
    content_node_ids: List[str] = []
    if primary_id:
        content_node_ids.append(primary_id)
    if "also" in query:
        extras = [unquote(e) for e in query.pop("also").split(",") if e]
        content_node_ids.extend(extras)
    return {
        "renderer_id": renderer_id,
        "content_node_ids": content_node_ids,
        "query": dict(sorted(query.items())),
    }


__all__ = ["translate", "parse_url"]
