"""Generic items list panel — reads ``engine.cache[source_id]`` and renders.

A single ItemsPanel renders one items channel as a vertical list of
cards with a status pill, title, expandable body, and a metadata
footer. The same primitive that ListRenderer (3D) and the Tk GUI
already consume — the Streamlit version is a third renderer over
exactly the same data shape.

To mount additional items-panels at once (e.g. Tasks + Ideas + Wishes
side by side), use ``workflow_panel.py`` which composes three of these.

This module's ``manifest()`` is parameter-less to keep the panel
contract simple; ``workflow_panel.py`` invokes the rendering helper
``render_items_list`` directly with concrete source ids rather than
mounting copies of this panel.
"""

from __future__ import annotations

from html import escape
from typing import Any, Dict, List

import streamlit as st

from tools.workflow_streamlit.panels._common import MOUNT_MAIN, PanelContext, PanelManifest


def manifest() -> PanelManifest:
    # Hidden by default — this module exists to provide ``render_items_list``
    # as a helper. Individual items panels mount through ``workflow_panel``.
    return PanelManifest(
        name="items",
        description="Generic items-from-cache list renderer (helper, not mounted directly).",
        mount_point=MOUNT_MAIN,
        order=999,
        hidden=True,
    )


def render(ctx: PanelContext) -> None:  # pragma: no cover - unused, kept for contract
    return


def render_items_list(
    ctx: PanelContext,
    *,
    title: str,
    source_id: str,
    empty_hint: str = "(no items)",
    max_items: int = 200,
) -> None:
    """Render the items at ``engine.cache[source_id]`` as cards.

    Defensive against missing / malformed cache entries so a broken
    upstream source doesn't crash the panel.
    """
    st.markdown(f"#### {escape(title)}")
    items = _items_from_cache(ctx, source_id)
    if not items:
        st.markdown(f'<div class="empty-hint">{escape(empty_hint)}</div>', unsafe_allow_html=True)
        return
    for item in items[:max_items]:
        _render_item_card(item, source_id)


def _items_from_cache(ctx: PanelContext, source_id: str) -> List[Dict[str, Any]]:
    entry = ctx.engine.cache.get(source_id, {})
    if not isinstance(entry, dict):
        return []
    items = entry.get("items")
    if not isinstance(items, list):
        return []
    return list(items)


def _render_item_card(item: Dict[str, Any], source_id: str) -> None:
    item_id = str(item.get("id", ""))
    title = str(item.get("title", "(untitled)"))
    body = str(item.get("body", "")).strip()
    status = str(item.get("status", "")).strip().lower() or "pending"
    pill = _status_pill_html(status)
    safe_title = escape(title)
    card_html = (
        '<div class="panel-card">'
        f'  <div class="title">{pill} {safe_title}</div>'
    )
    if item_id:
        card_html += f'  <div class="meta">id {escape(item_id)}</div>'
    card_html += "</div>"
    st.markdown(card_html, unsafe_allow_html=True)
    if body:
        with st.expander("body", expanded=False):
            st.text(body)


def _status_pill_html(status: str) -> str:
    cls_map = {
        "ok": "status-pill status-pill-ok",
        "done": "status-pill status-pill-ok",
        "granted": "status-pill status-pill-ok",
        "resolved": "status-pill status-pill-ok",
        "pending": "status-pill status-pill-pending",
        "in_progress": "status-pill status-pill-in_progress",
        "planning": "status-pill status-pill-in_progress",
        "granting": "status-pill status-pill-in_progress",
        "alert": "status-pill status-pill-alert",
        "error": "status-pill status-pill-alert",
        "cancelled": "status-pill status-pill-cancelled",
        "superseded": "status-pill status-pill-cancelled",
    }
    cls = cls_map.get(status, "status-pill status-pill-pending")
    return f'<span class="{cls}">{escape(status)}</span>'
