"""test_sliding_window.py — tests for the pure-function band logic.

Per brief 02 commit 2 (Decision B1, SPEC-086).

Covers:
- `parse_window_param()` — None, int, CSV, tuple, malformed input.
- `select_window()` — empty positions, anchor, scroll_y, scroll-to-bottom
  default, window override, boundary cases (start, end, exactly at
  buffer threshold).
- `compute_lazy_load_trigger()` — fires at 50% buffer crossed; None
  inside the buffer zone.
- `compute_scroll_velocity()` + `is_fast_scroll()` — Decision B7's
  fast-scroll threshold (>5 vp/s engages placeholder mode).

The sliding_window module is a PURE function with no I/O — these tests
exercise the algebra directly without spinning up an engine or a
substrate.

Run:
    cd Apeiron && python -m pytest tests/test_sliding_window.py -v
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

APEIRON_ROOT = Path(__file__).parent.parent.resolve()
if str(APEIRON_ROOT) not in sys.path:
    sys.path.insert(0, str(APEIRON_ROOT))

from tools.workflow_streamlit.renderers.sliding_window import (  # noqa: E402
    DEFAULT_BUFFER_ABOVE,
    DEFAULT_BUFFER_BELOW,
    DEFAULT_VISIBLE,
    FAST_SCROLL_VELOCITY_THRESHOLD,
    compute_lazy_load_trigger,
    compute_scroll_velocity,
    is_fast_scroll,
    parse_window_param,
    select_window,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _mk_positions(n: int) -> list:
    """Build n synthetic position entries (node_id_0, node_id_1, ...)."""
    return [
        {
            "node_id": f"sha256:{i:064x}",
            "appended_at": f"2026-05-22T00:00:{i:02d}Z",
            "provenance": {"source": "test"},
        }
        for i in range(n)
    ]


# ---------------------------------------------------------------------------
# parse_window_param
# ---------------------------------------------------------------------------


def test_parse_window_param_none_returns_defaults() -> None:
    assert parse_window_param(None) == (
        DEFAULT_VISIBLE,
        DEFAULT_BUFFER_ABOVE,
        DEFAULT_BUFFER_BELOW,
    )


def test_parse_window_param_empty_string_returns_defaults() -> None:
    assert parse_window_param("") == (
        DEFAULT_VISIBLE,
        DEFAULT_BUFFER_ABOVE,
        DEFAULT_BUFFER_BELOW,
    )


def test_parse_window_param_csv_triple_parses() -> None:
    assert parse_window_param("10,5,5") == (10, 5, 5)
    assert parse_window_param(" 10 , 5 , 5 ") == (10, 5, 5)


def test_parse_window_param_tuple_passthrough() -> None:
    assert parse_window_param((100, 50, 50)) == (100, 50, 50)


def test_parse_window_param_list_passthrough() -> None:
    assert parse_window_param([100, 50, 50]) == (100, 50, 50)


def test_parse_window_param_single_int_uses_defaults_for_buffers() -> None:
    assert parse_window_param(25) == (25, DEFAULT_BUFFER_ABOVE, DEFAULT_BUFFER_BELOW)
    assert parse_window_param("25") == (
        25,
        DEFAULT_BUFFER_ABOVE,
        DEFAULT_BUFFER_BELOW,
    )


def test_parse_window_param_rejects_two_part_csv() -> None:
    with pytest.raises(ValueError):
        parse_window_param("10,5")


def test_parse_window_param_rejects_non_int_csv() -> None:
    with pytest.raises(ValueError):
        parse_window_param("10,foo,5")


def test_parse_window_param_rejects_negative_values() -> None:
    with pytest.raises(ValueError):
        parse_window_param("10,-5,5")
    with pytest.raises(ValueError):
        parse_window_param((10, 5, -1))


def test_parse_window_param_rejects_non_int_tuple_entry() -> None:
    with pytest.raises(ValueError):
        parse_window_param((10, "five", 5))


def test_parse_window_param_rejects_wrong_arity_tuple() -> None:
    with pytest.raises(ValueError):
        parse_window_param((10, 5))


def test_parse_window_param_rejects_invalid_type() -> None:
    with pytest.raises(ValueError):
        parse_window_param({"visible": 10})  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# select_window — empty + boundary cases
# ---------------------------------------------------------------------------


def test_select_window_empty_positions_returns_empty_lists() -> None:
    bands = select_window(positions=[])
    assert bands == {
        "visible": [],
        "buffer_above": [],
        "buffer_below": [],
        "evicted": [],
    }


def test_select_window_rejects_non_list_positions() -> None:
    with pytest.raises(TypeError):
        select_window(positions="not-a-list")  # type: ignore[arg-type]


def test_select_window_rejects_non_positive_viewport_height() -> None:
    positions = _mk_positions(10)
    with pytest.raises(ValueError):
        select_window(positions=positions, viewport_height=0)
    with pytest.raises(ValueError):
        select_window(positions=positions, viewport_height=-100)


def test_select_window_short_positions_fits_in_visible_band() -> None:
    """When positions has fewer entries than the visible-band size, all
    entries land in visible and the buffer bands are empty."""
    positions = _mk_positions(10)
    bands = select_window(positions=positions, window_param=(50, 20, 20))
    assert len(bands["visible"]) == 10
    assert bands["buffer_above"] == []
    assert bands["buffer_below"] == []
    assert bands["evicted"] == []


# ---------------------------------------------------------------------------
# select_window — scroll-to-bottom default
# ---------------------------------------------------------------------------


def test_select_window_scroll_to_bottom_with_100_nodes_default_window() -> None:
    """100 nodes, default 50+20+20 window, scroll-to-bottom default:
    the last 50 are visible, the 20 before that are buffer_above, no
    buffer_below (we're at the bottom), 30 evicted at the top."""
    positions = _mk_positions(100)
    bands = select_window(positions=positions)
    assert len(bands["visible"]) == 50
    assert len(bands["buffer_above"]) == 20
    assert len(bands["buffer_below"]) == 0
    assert len(bands["evicted"]) == 30
    # Visible spans positions 50..99 (the newest).
    assert bands["visible"][0] == positions[50]["node_id"]
    assert bands["visible"][-1] == positions[99]["node_id"]
    # Buffer-above spans 30..49.
    assert bands["buffer_above"][0] == positions[30]["node_id"]
    assert bands["buffer_above"][-1] == positions[49]["node_id"]
    # Evicted is 0..29.
    assert bands["evicted"][0] == positions[0]["node_id"]
    assert bands["evicted"][-1] == positions[29]["node_id"]


def test_select_window_scroll_to_bottom_with_30_nodes() -> None:
    """30 nodes, default window: visible holds all 30 (window is bigger
    than positions), buffer_above hits the array start, no buffer_below."""
    positions = _mk_positions(30)
    bands = select_window(positions=positions)
    # visible_size=50 > 30 positions; visible_start clips to 0; visible spans 0..30.
    assert len(bands["visible"]) == 30
    assert bands["buffer_above"] == []
    assert bands["buffer_below"] == []


def test_select_window_total_dom_size_is_visible_plus_buffers() -> None:
    """The renderer's DOM bound: visible + buffer_above + buffer_below."""
    positions = _mk_positions(1000)
    bands = select_window(positions=positions)
    rendered = (
        len(bands["visible"]) + len(bands["buffer_above"]) + len(bands["buffer_below"])
    )
    assert rendered == 70  # 50 + 20 + 0 (we're at the bottom)
    assert len(bands["evicted"]) == 1000 - 70


# ---------------------------------------------------------------------------
# select_window — anchor
# ---------------------------------------------------------------------------


def test_select_window_with_anchor_centers_window() -> None:
    """Anchor at index 50 of 100 positions: visible spans ~[26..74]
    (centered), buffer above + below both present."""
    positions = _mk_positions(100)
    anchor_node_id = positions[50]["node_id"]
    bands = select_window(
        positions=positions, anchor_or_scroll_position={"anchor": anchor_node_id}
    )
    assert anchor_node_id in bands["visible"]
    assert len(bands["visible"]) == 50
    assert len(bands["buffer_above"]) == 20
    assert len(bands["buffer_below"]) == 20


def test_select_window_anchor_near_start_clips_buffer_above() -> None:
    positions = _mk_positions(100)
    anchor_node_id = positions[2]["node_id"]
    bands = select_window(
        positions=positions,
        anchor_or_scroll_position={"anchor": anchor_node_id},
    )
    assert anchor_node_id in bands["visible"]
    # Visible starts at 0; buffer_above is empty.
    assert bands["buffer_above"] == []
    assert bands["visible"][0] == positions[0]["node_id"]


def test_select_window_anchor_near_end_clips_buffer_below() -> None:
    positions = _mk_positions(100)
    anchor_node_id = positions[98]["node_id"]
    bands = select_window(
        positions=positions,
        anchor_or_scroll_position={"anchor": anchor_node_id},
    )
    assert anchor_node_id in bands["visible"]
    # The last entry is included; buffer_below empty.
    assert bands["visible"][-1] == positions[99]["node_id"]
    assert bands["buffer_below"] == []


def test_select_window_anchor_not_in_positions_raises() -> None:
    positions = _mk_positions(10)
    with pytest.raises(ValueError) as exc_info:
        select_window(
            positions=positions,
            anchor_or_scroll_position={"anchor": "sha256:nonexistent"},
        )
    assert "anchor" in str(exc_info.value)


# ---------------------------------------------------------------------------
# select_window — window override
# ---------------------------------------------------------------------------


def test_select_window_window_override_csv() -> None:
    positions = _mk_positions(100)
    bands = select_window(positions=positions, window_param="10,5,5")
    assert len(bands["visible"]) == 10
    assert len(bands["buffer_above"]) == 5
    assert len(bands["buffer_below"]) == 0  # scroll-to-bottom default
    assert len(bands["evicted"]) == 100 - 15


def test_select_window_window_override_tuple() -> None:
    positions = _mk_positions(100)
    bands = select_window(positions=positions, window_param=(10, 5, 5))
    assert len(bands["visible"]) == 10
    assert len(bands["buffer_above"]) == 5


def test_select_window_window_override_with_anchor() -> None:
    """The window override works in anchor mode too — both buffer bands
    are populated."""
    positions = _mk_positions(100)
    anchor_node_id = positions[50]["node_id"]
    bands = select_window(
        positions=positions,
        anchor_or_scroll_position={"anchor": anchor_node_id},
        window_param=(10, 5, 5),
    )
    assert len(bands["visible"]) == 10
    assert len(bands["buffer_above"]) == 5
    assert len(bands["buffer_below"]) == 5


# ---------------------------------------------------------------------------
# select_window — scroll_y heuristic
# ---------------------------------------------------------------------------


def test_select_window_with_scroll_y_uses_per_node_height_heuristic() -> None:
    positions = _mk_positions(100)
    # scroll_y=4000 / per_node_height=80 = index 50.
    bands = select_window(
        positions=positions,
        anchor_or_scroll_position={"scroll_y": 4000},
        per_node_height=80,
    )
    expected_center = positions[50]["node_id"]
    assert expected_center in bands["visible"]


def test_select_window_scroll_y_clips_to_array_bounds() -> None:
    positions = _mk_positions(10)
    # scroll_y way beyond the array → clipped to last entry.
    bands = select_window(
        positions=positions,
        anchor_or_scroll_position={"scroll_y": 999999},
    )
    assert positions[9]["node_id"] in bands["visible"]


def test_select_window_explicit_index_anchor_test_convenience() -> None:
    positions = _mk_positions(100)
    bands = select_window(
        positions=positions,
        anchor_or_scroll_position={"index": 25},
    )
    assert positions[25]["node_id"] in bands["visible"]


# ---------------------------------------------------------------------------
# select_window — boundary edge cases
# ---------------------------------------------------------------------------


def test_select_window_evicted_is_disjoint_from_rendered() -> None:
    """The eviction band shares no ids with visible / buffer bands."""
    positions = _mk_positions(200)
    bands = select_window(positions=positions, window_param=(10, 5, 5))
    rendered = set(bands["visible"]) | set(bands["buffer_above"]) | set(
        bands["buffer_below"]
    )
    evicted = set(bands["evicted"])
    assert rendered.isdisjoint(evicted)
    assert rendered | evicted == set(p["node_id"] for p in positions)


def test_select_window_skips_entries_without_node_id() -> None:
    """Position entries missing a node_id (defensive: malformed input)
    are filtered out of the output rather than yielding None."""
    positions = [{"node_id": "a"}, {"appended_at": "x"}, {"node_id": "b"}]
    bands = select_window(positions=positions)
    all_ids = bands["visible"] + bands["buffer_above"] + bands["buffer_below"]
    assert "a" in all_ids
    assert "b" in all_ids
    assert None not in all_ids


# ---------------------------------------------------------------------------
# compute_lazy_load_trigger
# ---------------------------------------------------------------------------


def test_compute_lazy_load_trigger_well_inside_buffer_returns_none() -> None:
    """When the viewport sits comfortably inside the buffer (well below
    50% consumption in either direction), no trigger fires."""
    # 100 px of buffer-above (20 buffer-above-nodes * 80 px/node), threshold
    # at 50% = 800 px. A viewport at scroll_y=-100 has only consumed
    # ~1 node above, well below the threshold. Same on the below side:
    # large buffer (50 entries) so the viewport-bottom at 800px is well
    # below the half-buffer threshold of 50/2 * 80 = 2000 px.
    current_window = {"buffer_above": ["a"] * 20, "buffer_below": ["b"] * 50}
    assert (
        compute_lazy_load_trigger(
            scroll_y=-100, viewport_height=800, current_window=current_window
        )
        is None
    )


def test_compute_lazy_load_trigger_scrolls_down_past_threshold() -> None:
    """Scrolling down past half of buffer_below should fire 'down'."""
    current_window = {"buffer_above": ["a"] * 20, "buffer_below": ["b"] * 20}
    # 20 buffer-below, per-node-height 80, half = 10 nodes = 800px past viewport-bottom.
    # scroll_y=800 puts the viewport-bottom at 1600px, which is 1600/80 = 20 nodes below.
    trigger = compute_lazy_load_trigger(
        scroll_y=800, viewport_height=800, current_window=current_window
    )
    assert trigger == "down"


def test_compute_lazy_load_trigger_scrolls_up_past_threshold() -> None:
    current_window = {"buffer_above": ["a"] * 20, "buffer_below": ["b"] * 20}
    # negative scroll_y means we've scrolled up past the visible band.
    trigger = compute_lazy_load_trigger(
        scroll_y=-1000, viewport_height=800, current_window=current_window
    )
    assert trigger == "up"


def test_compute_lazy_load_trigger_empty_buffer_returns_none() -> None:
    current_window = {"buffer_above": [], "buffer_below": []}
    trigger = compute_lazy_load_trigger(800, 800, current_window)
    assert trigger is None


# ---------------------------------------------------------------------------
# compute_scroll_velocity + is_fast_scroll
# ---------------------------------------------------------------------------


def test_compute_scroll_velocity_empty_history_returns_zero() -> None:
    assert compute_scroll_velocity([], 800) == 0.0


def test_compute_scroll_velocity_single_sample_returns_zero() -> None:
    assert compute_scroll_velocity([(0.0, 0)], 800) == 0.0


def test_compute_scroll_velocity_zero_timespan_returns_zero() -> None:
    """Two samples at the same timestamp should not divide by zero."""
    assert compute_scroll_velocity([(0.0, 0), (0.0, 1000)], 800) == 0.0


def test_compute_scroll_velocity_slow_scroll() -> None:
    """1000 px in 2 seconds at 800px viewport = 500px/s / 800px = 0.625 vp/s."""
    velocity = compute_scroll_velocity([(0.0, 0), (2.0, 1000)], 800)
    assert abs(velocity - 0.625) < 1e-6


def test_compute_scroll_velocity_fast_scroll() -> None:
    """8000 px in 1 second at 800px viewport = 10 vp/s."""
    velocity = compute_scroll_velocity([(0.0, 0), (1.0, 8000)], 800)
    assert abs(velocity - 10.0) < 1e-6


def test_is_fast_scroll_below_threshold() -> None:
    assert (
        is_fast_scroll([(0.0, 0), (1.0, 800)], 800) is False
    )


def test_is_fast_scroll_above_threshold() -> None:
    assert (
        is_fast_scroll([(0.0, 0), (1.0, 8000)], 800) is True
    )


def test_is_fast_scroll_threshold_value() -> None:
    """Sanity-check the threshold matches Decision B7's 5 vp/s."""
    assert FAST_SCROLL_VELOCITY_THRESHOLD == 5.0
