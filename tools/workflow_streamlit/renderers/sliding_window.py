"""sliding_window — pure-function band-selection logic for the workflow surface.

Per brief 02 commit 2 (Decision B1, SPEC-086).

The continuous-scroll workflow surface maintains a sliding window of
nodes in the DOM. Three concentric bands:

- **Visible band** — the nodes currently in the viewport. Variable count
  in principle (depends on viewport height and per-node height); the
  upper bound is the URL `?window=<N>,...` override (default N=50).
- **Buffer band** — `B_above` nodes above the topmost visible node plus
  `B_below` nodes below the bottommost visible node. Pre-rendered + in
  DOM, allowing smooth scroll-by-half-viewport without a fetch hiccup.
- **Eviction band** — nodes beyond the buffer are NOT in the DOM. Their
  HTML is discarded; their workflow position is remembered (the renderer
  holds a list of every entry in `positions`, not just rendered ones).

`select_window(positions, anchor_or_scroll_position, viewport_height,
window_param) -> {visible, buffer_above, buffer_below, evicted}` is the
canonical entry point. It is a PURE FUNCTION — no engine access, no
side-effects, no I/O. The renderer's HTML-emission layer composes
against this function; test harnesses (Tool T1
`scroll_window.py`) call it directly to verify the band logic without
spinning up Streamlit.

This module also exports two related helpers:

- `compute_lazy_load_trigger(scroll_y, viewport_height, current_window)`
  — returns 'up' | 'down' | None per Decision B1's threshold rule (50%
  of buffer crossed toward an edge).
- `compute_scroll_velocity(scroll_history)` — returns viewports-per-
  second per Decision B7's fast-scroll detection (>5 vp/s engages
  placeholder-only render).

The numbers in the function signatures (defaults, thresholds) are
declared as module-level constants so callers / tests can override them
without monkey-patching. The phase-1 defaults match SPEC-086 + Decision
B1/B7 verbatim; a phase-2 might tune them under load without touching
the band-selection algebra.
"""
from __future__ import annotations

from typing import Any, Dict, List, Optional, Tuple


# ---------------------------------------------------------------------------
# Defaults (SPEC-086 + Decision B1/B7)
# ---------------------------------------------------------------------------

DEFAULT_VISIBLE = 50
DEFAULT_BUFFER_ABOVE = 20
DEFAULT_BUFFER_BELOW = 20

# Lazy-load fires when the user scrolls past this fraction of the buffer
# band toward the edge. Decision B1: 50%.
LAZY_LOAD_THRESHOLD_FRACTION = 0.5

# Fast-scroll engages placeholder-only mode above this scroll velocity
# (viewport-heights per second). Decision B7: 5 vp/s.
FAST_SCROLL_VELOCITY_THRESHOLD = 5.0

# Average per-node-height assumption for scroll-y-to-index conversion
# (pixels). The renderer does NOT measure individual node heights at
# select-time — the lazy-load JS in the renderer's <script> block reports
# scroll position back as a node-index hint when available; otherwise the
# pure function uses this heuristic. Override per-instance via
# `select_window(..., per_node_height=...)`.
DEFAULT_PER_NODE_HEIGHT_PX = 80


# ---------------------------------------------------------------------------
# Window-param parsing
# ---------------------------------------------------------------------------


def parse_window_param(
    window_param: Optional[str | Tuple[int, int, int]] = None,
) -> Tuple[int, int, int]:
    """Parse a `?window=N,B_above,B_below` query-string override.

    Accepts:
      - None → defaults (50, 20, 20).
      - A 3-tuple of ints → returned verbatim (after validation).
      - A CSV string like "50,20,20" → parsed into a 3-tuple.
      - A single int (or stringified int) → treated as visible-band size,
        buffer defaults kept.

    Raises `ValueError` on malformed input — the caller chooses whether
    to fall back to defaults or surface the error.
    """
    if window_param is None or window_param == "":
        return (DEFAULT_VISIBLE, DEFAULT_BUFFER_ABOVE, DEFAULT_BUFFER_BELOW)
    if isinstance(window_param, (tuple, list)):
        if len(window_param) != 3:
            raise ValueError(
                f"parse_window_param: tuple/list must have 3 entries "
                f"(visible, buffer_above, buffer_below); got {window_param!r}"
            )
        return _validate_window_triple(window_param)
    if isinstance(window_param, int):
        return _validate_window_triple(
            (window_param, DEFAULT_BUFFER_ABOVE, DEFAULT_BUFFER_BELOW)
        )
    if not isinstance(window_param, str):
        raise ValueError(
            f"parse_window_param: window_param must be None, int, str, or "
            f"tuple; got {type(window_param).__name__}"
        )
    parts = [p.strip() for p in window_param.split(",") if p.strip()]
    if len(parts) == 1:
        try:
            return _validate_window_triple(
                (int(parts[0]), DEFAULT_BUFFER_ABOVE, DEFAULT_BUFFER_BELOW)
            )
        except ValueError as exc:
            raise ValueError(
                f"parse_window_param: could not parse {window_param!r} as int: {exc}"
            )
    if len(parts) != 3:
        raise ValueError(
            f"parse_window_param: expected 'N,B_above,B_below' (3 ints); "
            f"got {window_param!r}"
        )
    try:
        triple = (int(parts[0]), int(parts[1]), int(parts[2]))
    except ValueError as exc:
        raise ValueError(
            f"parse_window_param: malformed CSV {window_param!r}: {exc}"
        )
    return _validate_window_triple(triple)


def _validate_window_triple(triple: Any) -> Tuple[int, int, int]:
    if not isinstance(triple, (tuple, list)) or len(triple) != 3:
        raise ValueError(
            f"window triple must be (visible, buffer_above, buffer_below); "
            f"got {triple!r}"
        )
    visible, ba, bb = triple
    for label, value in (("visible", visible), ("buffer_above", ba), ("buffer_below", bb)):
        if not isinstance(value, int):
            raise ValueError(
                f"window triple: '{label}' must be int; got {value!r} "
                f"({type(value).__name__})"
            )
        if value < 0:
            raise ValueError(
                f"window triple: '{label}' must be non-negative; got {value}"
            )
    return (int(visible), int(ba), int(bb))


# ---------------------------------------------------------------------------
# Anchor / scroll resolution
# ---------------------------------------------------------------------------


def _resolve_anchor_index(
    positions: List[dict],
    anchor_or_scroll: Optional[Dict[str, Any]],
    per_node_height: int,
) -> int:
    """Compute the centre-index into `positions` for the visible band.

    `anchor_or_scroll` shapes:
      - None — center on the last entry (the maintainer's "chat-like
        scroll-to-bottom" boot per Decision B6).
      - `{"anchor": <content_node_id>}` — find the matching entry; raise
        ValueError if absent.
      - `{"scroll_y": <pixels>}` — heuristic conversion using
        `per_node_height`.
      - `{"index": <int>}` — explicit index (test convenience).

    Returns the integer center-index. The caller slices around it.
    """
    if not positions:
        # Empty workflow_view; the caller should short-circuit before
        # calling, but we return 0 as a deterministic default.
        return 0
    n = len(positions)
    if anchor_or_scroll is None:
        return n - 1  # scroll-to-bottom

    anchor = anchor_or_scroll.get("anchor")
    if isinstance(anchor, str) and anchor:
        for i, entry in enumerate(positions):
            if isinstance(entry, dict) and entry.get("node_id") == anchor:
                return i
        raise ValueError(
            f"select_window: anchor {anchor!r} not found in positions "
            f"(positions has {n} entries)"
        )

    explicit_index = anchor_or_scroll.get("index")
    if isinstance(explicit_index, int):
        return max(0, min(n - 1, explicit_index))

    scroll_y = anchor_or_scroll.get("scroll_y")
    if isinstance(scroll_y, (int, float)):
        if per_node_height <= 0:
            raise ValueError(
                f"select_window: per_node_height must be positive when "
                f"scroll_y is used; got {per_node_height}"
            )
        idx = int(scroll_y // per_node_height)
        return max(0, min(n - 1, idx))

    # No usable anchor — fall back to scroll-to-bottom rather than crash.
    return n - 1


# ---------------------------------------------------------------------------
# Core band selection
# ---------------------------------------------------------------------------


def select_window(
    positions: List[dict],
    anchor_or_scroll_position: Optional[Dict[str, Any]] = None,
    viewport_height: int = 800,
    window_param: Optional[str | Tuple[int, int, int]] = None,
    per_node_height: int = DEFAULT_PER_NODE_HEIGHT_PX,
) -> Dict[str, List[str]]:
    """Compute the rendered + buffered + evicted node-id lists.

    Pure function — no engine access, no side-effects.

    Inputs:
      positions: the workflow_view's positions list (each entry a dict
        with at least `node_id: str`).
      anchor_or_scroll_position: see `_resolve_anchor_index` for accepted
        shapes. None means scroll-to-bottom.
      viewport_height: pixel height of the visible viewport. Used to
        heuristically size the visible band when the URL override is not
        an explicit triple; otherwise informational.
      window_param: optional URL override per `parse_window_param`.
      per_node_height: heuristic per-node pixel height for scroll-y to
        index conversion.

    Output keys:
      visible: list of content_node_ids in the visible band (chronological
        order — older first, newer last).
      buffer_above: list of ids above the topmost visible node (in the
        order they appear in positions, older→newer).
      buffer_below: list of ids below the bottommost visible node
        (older→newer).
      evicted: list of ids outside the visible+buffer bands (the rest of
        positions). The renderer does NOT emit DOM for these.

    Edge cases:
      - Empty positions → all four lists empty.
      - Positions shorter than visible band → visible = all, buffers
        empty, evicted empty.
      - Anchor near the start/end → buffer truncates against the array
        boundary; visible band stays as large as possible without
        overflow.
    """
    if not isinstance(positions, list):
        raise TypeError(
            f"select_window: positions must be a list; got {type(positions).__name__}"
        )
    if viewport_height <= 0:
        raise ValueError(
            f"select_window: viewport_height must be positive; got {viewport_height}"
        )

    visible_size, buffer_above_size, buffer_below_size = parse_window_param(
        window_param
    )

    n = len(positions)
    if n == 0:
        return {
            "visible": [],
            "buffer_above": [],
            "buffer_below": [],
            "evicted": [],
        }

    # Extract the canonical node-id list once; surface entries that lack
    # node_id as None so off-by-one errors at the boundary surface as
    # explicit anomalies rather than silent shifts.
    ids: List[Optional[str]] = []
    for entry in positions:
        if isinstance(entry, dict):
            ids.append(entry.get("node_id"))
        else:
            ids.append(None)

    center_idx = _resolve_anchor_index(
        positions, anchor_or_scroll_position, per_node_height
    )

    # Build the visible band around the center. The bottom of the
    # viewport tends to anchor (chat-like default) — for scroll-to-bottom
    # this means visible ends at center_idx; for anchor or scroll the
    # anchor is centered.
    is_scroll_to_bottom = anchor_or_scroll_position is None
    if is_scroll_to_bottom:
        # The newest entry is at the bottom; visible band ends at center.
        visible_end_exclusive = center_idx + 1
        visible_start = max(0, visible_end_exclusive - visible_size)
    else:
        # Center the anchor in the visible band.
        half_above = visible_size // 2
        half_below = visible_size - half_above - 1  # -1 for the anchor itself
        visible_start = max(0, center_idx - half_above)
        visible_end_exclusive = min(n, visible_start + visible_size)
        # If we hit the right edge, shift left to keep visible_size.
        if visible_end_exclusive - visible_start < visible_size:
            visible_start = max(0, visible_end_exclusive - visible_size)

    # Clip against array boundaries.
    visible_start = max(0, visible_start)
    visible_end_exclusive = min(n, visible_end_exclusive)
    if visible_end_exclusive <= visible_start:
        # Defensive: produce a single-entry visible band at the center.
        visible_end_exclusive = min(n, visible_start + 1)

    visible_ids = [ids[i] for i in range(visible_start, visible_end_exclusive)]

    # Buffer bands.
    buffer_above_start = max(0, visible_start - buffer_above_size)
    buffer_above_ids = [ids[i] for i in range(buffer_above_start, visible_start)]

    buffer_below_end_exclusive = min(n, visible_end_exclusive + buffer_below_size)
    buffer_below_ids = [
        ids[i] for i in range(visible_end_exclusive, buffer_below_end_exclusive)
    ]

    # Evicted: everything outside buffer_above_start ... buffer_below_end_exclusive
    rendered_indices = set(range(buffer_above_start, buffer_below_end_exclusive))
    evicted_ids = [ids[i] for i in range(n) if i not in rendered_indices]

    return {
        "visible": _filter_nones(visible_ids),
        "buffer_above": _filter_nones(buffer_above_ids),
        "buffer_below": _filter_nones(buffer_below_ids),
        "evicted": _filter_nones(evicted_ids),
    }


def _filter_nones(xs: List[Optional[str]]) -> List[str]:
    return [x for x in xs if isinstance(x, str)]


# ---------------------------------------------------------------------------
# Decision B1 — lazy-load trigger
# ---------------------------------------------------------------------------


def compute_lazy_load_trigger(
    scroll_y: int,
    viewport_height: int,
    current_window: Dict[str, List[str]],
    per_node_height: int = DEFAULT_PER_NODE_HEIGHT_PX,
    threshold_fraction: float = LAZY_LOAD_THRESHOLD_FRACTION,
) -> Optional[str]:
    """Return 'up' / 'down' / None per Decision B1 + SPEC-086.

    Fires when the user scrolls past `threshold_fraction` of the buffer
    band toward an edge. The renderer's `<script>` posts these triggers
    back to the panel via the CLI bridge; the panel re-calls
    `select_window()` with the new scroll position.

    The function is intentionally simple — it does NOT track scroll
    history (that's `compute_scroll_velocity`); a single tick decides
    'load more in this direction' or not.
    """
    buffer_above = len(current_window.get("buffer_above", []))
    buffer_below = len(current_window.get("buffer_below", []))

    # Estimate the "depth into the buffer" via per-node-height heuristic.
    # When the JS reports an explicit scroll-y, the renderer maps it back
    # into "nodes-past-the-edge."
    if per_node_height <= 0:
        return None

    nodes_above_viewport_top = max(0, -scroll_y // per_node_height)
    nodes_below_viewport_bottom = max(
        0, (scroll_y + viewport_height) // per_node_height
    )

    # If scrolled enough INTO the buffer-above band that we've consumed
    # `threshold_fraction` of it, request 'up'.
    if buffer_above > 0:
        above_consumed = nodes_above_viewport_top
        if above_consumed >= int(buffer_above * threshold_fraction):
            return "up"

    if buffer_below > 0:
        below_consumed = nodes_below_viewport_bottom
        if below_consumed >= int(buffer_below * threshold_fraction):
            return "down"

    return None


# ---------------------------------------------------------------------------
# Decision B7 — fast-scroll velocity detection
# ---------------------------------------------------------------------------


def compute_scroll_velocity(
    scroll_history: List[Tuple[float, int]],
    viewport_height: int,
) -> float:
    """Return scroll velocity in viewport-heights-per-second.

    `scroll_history` is a list of `(timestamp_seconds, scroll_y_pixels)`
    samples in chronological order. Uses the first + last samples as the
    integration window; intermediate samples are ignored (a smoother
    estimator could weight them, but the placeholder-mode decision is
    coarse-grained so the linear estimate is sufficient).

    Returns 0.0 when fewer than 2 samples are supplied, OR when the
    timespan is zero (avoids division by zero — caller should never see
    `inf`).
    """
    if not isinstance(scroll_history, list) or len(scroll_history) < 2:
        return 0.0
    if viewport_height <= 0:
        return 0.0
    t0, y0 = scroll_history[0]
    t1, y1 = scroll_history[-1]
    dt = t1 - t0
    if dt <= 0:
        return 0.0
    pixels_per_second = abs(y1 - y0) / dt
    return pixels_per_second / viewport_height


def is_fast_scroll(
    scroll_history: List[Tuple[float, int]],
    viewport_height: int,
    threshold_vps: float = FAST_SCROLL_VELOCITY_THRESHOLD,
) -> bool:
    """Convenience predicate — returns True iff velocity exceeds the
    fast-scroll threshold per Decision B7 (default >5 vp/s)."""
    return compute_scroll_velocity(scroll_history, viewport_height) > threshold_vps
