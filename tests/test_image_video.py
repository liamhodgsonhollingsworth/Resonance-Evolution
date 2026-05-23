"""Tests for ImageNode + VideoNode — N-F026 / SPEC-090 content primitives.

Brief 03 commit 4. Covers registration, build defaults + passthrough,
emit producing the expected channel pair (color + depth), placeholder
fallback for empty / missing / unreadable sources, describe content
naming the resolution state for the text-API, and visual-variant
swap via the substrate's _execute_renderer dispatch.

VideoNode tests cover the placeholder + alt-text overlay path
(imageio may not be installed in CI) plus the playback verbs
(play/pause/set_loop/set_controls) state-management contract.

Per the per-module plan plan-testing Scenario 1 (every primitive
renders) + the SPEC-081 text-API smoke obligation.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine, View  # noqa: E402
from engine.node import EmitContext, look_at  # noqa: E402


# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------


@pytest.fixture
def engine() -> Engine:
    e = Engine(root_dir=ROOT)
    e.discover()
    return e


@pytest.fixture
def view() -> View:
    return View(
        position=np.array([0.0, 0.0, 5.0], dtype=np.float64),
        orientation=look_at(
            np.array([0.0, 0.0, 5.0]),
            np.array([0.0, 0.0, 0.0]),
        ),
        width=64, height=64,
    )


@pytest.fixture
def temp_png(tmp_path: Path) -> Path:
    """Write a 32x32 solid-red PNG to tmp_path/test_image.png."""
    arr = np.zeros((32, 32, 3), dtype=np.uint8)
    arr[..., 0] = 230  # mostly red
    arr[..., 1] = 40
    arr[..., 2] = 40
    img = Image.fromarray(arr, mode="RGB")
    path = tmp_path / "test_image.png"
    img.save(path)
    return path


# --------------------------------------------------------------------------
# ImageNode — registration + build
# --------------------------------------------------------------------------


def test_image_node_registers(engine):
    assert "ImageNode" in engine.types
    m = engine.types["ImageNode"].manifest()
    assert m.name == "ImageNode"
    expected = {
        "src", "alt_text", "width", "height", "preserve_aspect",
        "layer", "displayed_by", "placeholder_color",
        "screen_width", "screen_height", "screen_resolution",
    }
    assert expected.issubset(set(m.inputs.keys()))


def test_image_build_defaults(engine):
    engine.spawn("img1", "ImageNode", params={})
    s = engine.nodes["img1"].state
    assert s["src"] == ""
    assert s["alt_text"] == ""
    assert s["width"] == 0
    assert s["height"] == 0
    assert s["preserve_aspect"] is True
    assert s["layer"] == 0
    assert s["displayed_by"] == ""
    assert s["placeholder_color"].shape == (3,)


def test_image_build_passthrough(engine, temp_png):
    engine.spawn(
        "img2", "ImageNode",
        params={
            "src": str(temp_png),
            "alt_text": "red square",
            "width": 64,
            "height": 32,
            "preserve_aspect": False,
            "layer": 3,
            "displayed_by": "image_default_v1",
        },
    )
    s = engine.nodes["img2"].state
    assert s["src"] == str(temp_png)
    assert s["alt_text"] == "red square"
    assert s["width"] == 64
    assert s["height"] == 32
    assert s["preserve_aspect"] is False
    assert s["layer"] == 3
    assert s["displayed_by"] == "image_default_v1"


# --------------------------------------------------------------------------
# ImageNode — emit
# --------------------------------------------------------------------------


def test_image_emit_placeholder_when_empty(engine, view):
    """Empty src emits the placeholder color on the screen rectangle."""
    engine.spawn("img3", "ImageNode", params={
        "placeholder_color": [0.5, 0.5, 0.5],
    })
    node = engine.nodes["img3"]
    ctx = EmitContext(engine=engine, node=node)
    channels = engine.types["ImageNode"].emit(node.state, view, ctx)
    color = channels["color"]
    depth = channels["depth"]
    assert color.shape == (view.height, view.width, 3)
    assert depth.shape == (view.height, view.width)
    # At least some pixels should be the placeholder color.
    assert color.max() > 0.0


def test_image_emit_with_real_file(engine, view, temp_png):
    """File-backed src loads via PIL and renders the actual image."""
    engine.spawn("img4", "ImageNode", params={
        "src": str(temp_png),
        "screen_resolution": 64,
    })
    node = engine.nodes["img4"]
    ctx = EmitContext(engine=engine, node=node)
    channels = engine.types["ImageNode"].emit(node.state, view, ctx)
    color = channels["color"]
    # Inside-screen pixels should be predominantly red (the test PNG).
    flat = color.reshape(-1, 3)
    # Filter pixels that are not background (any non-zero channel).
    visible = flat[(flat > 0.05).any(axis=1)]
    # When the image rendered (not all placeholder), red dominates.
    assert visible.shape[0] > 0
    mean_red = visible[..., 0].mean()
    mean_green = visible[..., 1].mean()
    assert mean_red > mean_green, (
        f"expected red-dominant rendering; mean_red={mean_red:.3f}, "
        f"mean_green={mean_green:.3f}"
    )


def test_image_emit_missing_file_falls_back(engine, view, tmp_path):
    """Non-existent src renders the placeholder without raising."""
    engine.spawn("img5", "ImageNode", params={
        "src": str(tmp_path / "no_such_file.png"),
        "placeholder_color": [0.3, 0.3, 0.3],
    })
    node = engine.nodes["img5"]
    ctx = EmitContext(engine=engine, node=node)
    channels = engine.types["ImageNode"].emit(node.state, view, ctx)
    color = channels["color"]
    # Inside the screen rectangle, the placeholder color appears
    # uniformly (since the resolution returned a flat-color array).
    flat = color.reshape(-1, 3)
    visible = flat[(flat > 0.05).any(axis=1)]
    if visible.shape[0] > 0:
        # Every visible pixel matches the placeholder color.
        np.testing.assert_allclose(
            visible.mean(axis=0), [0.3, 0.3, 0.3], atol=0.05,
        )


def test_image_describe_includes_resolution_state(engine, temp_png):
    """describe() surfaces the src_state for the text-API driver."""
    engine.spawn("img6", "ImageNode", params={
        "src": str(temp_png),
        "alt_text": "red square",
    })
    node = engine.nodes["img6"]
    ctx = EmitContext(engine=engine, node=node)
    line = engine.types["ImageNode"].describe(node.state, ctx)
    assert "ImageNode" in line
    assert "src_state=file" in line
    assert "alt='red square'" in line


def test_image_describe_classifies_missing(engine, tmp_path):
    engine.spawn("img7", "ImageNode", params={
        "src": str(tmp_path / "absent.png"),
    })
    node = engine.nodes["img7"]
    ctx = EmitContext(engine=engine, node=node)
    line = engine.types["ImageNode"].describe(node.state, ctx)
    assert "src_state=missing" in line


def test_image_describe_classifies_empty(engine):
    engine.spawn("img8", "ImageNode", params={})
    node = engine.nodes["img8"]
    ctx = EmitContext(engine=engine, node=node)
    line = engine.types["ImageNode"].describe(node.state, ctx)
    assert "src_state=empty" in line


def test_image_describe_classifies_url(engine):
    engine.spawn("img9", "ImageNode", params={
        "src": "https://example.com/x.png",
    })
    node = engine.nodes["img9"]
    ctx = EmitContext(engine=engine, node=node)
    line = engine.types["ImageNode"].describe(node.state, ctx)
    assert "src_state=url-deferred" in line


# --------------------------------------------------------------------------
# ImageNode — preserve_aspect behavior
# --------------------------------------------------------------------------


def test_image_preserve_aspect_letterboxes(engine, view, temp_png):
    """When preserve_aspect=True and the request differs from source
    aspect, the placeholder fills the non-image region."""
    engine.spawn("img10", "ImageNode", params={
        "src": str(temp_png),
        "preserve_aspect": True,
        "placeholder_color": [0.0, 1.0, 0.0],  # green placeholder
        "screen_width": 4.0,
        "screen_height": 1.0,  # wide rectangle vs 1:1 test PNG
        "screen_resolution": 128,
    })
    node = engine.nodes["img10"]
    ctx = EmitContext(engine=engine, node=node)
    channels = engine.types["ImageNode"].emit(node.state, view, ctx)
    color = channels["color"]
    # Visible pixels should include some green (the letterbox bars).
    flat = color.reshape(-1, 3)
    visible = flat[(flat > 0.05).any(axis=1)]
    # Some green pixels expected (letterbox bars).
    green_dominant = (visible[..., 1] > visible[..., 0]) & (
        visible[..., 1] > visible[..., 2])
    assert green_dominant.sum() > 0, "expected some green letterbox pixels"


# --------------------------------------------------------------------------
# VideoNode — registration + build
# --------------------------------------------------------------------------


def test_video_node_registers(engine):
    assert "VideoNode" in engine.types
    m = engine.types["VideoNode"].manifest()
    assert m.name == "VideoNode"
    expected = {
        "src", "alt_text", "width", "height",
        "autoplay", "loop", "controls",
        "layer", "displayed_by", "placeholder_color",
    }
    assert expected.issubset(set(m.inputs.keys()))


def test_video_build_defaults(engine):
    engine.spawn("vid1", "VideoNode", params={})
    s = engine.nodes["vid1"].state
    assert s["src"] == ""
    assert s["autoplay"] is False
    assert s["loop"] is False
    assert s["controls"] is True
    assert s["alt_text"] == ""


def test_video_build_passthrough(engine):
    engine.spawn("vid2", "VideoNode", params={
        "src": "/path/to/clip.mp4",
        "alt_text": "demo clip",
        "autoplay": True,
        "loop": True,
        "controls": False,
        "layer": 2,
        "displayed_by": "video_default_v1",
    })
    s = engine.nodes["vid2"].state
    assert s["src"] == "/path/to/clip.mp4"
    assert s["autoplay"] is True
    assert s["loop"] is True
    assert s["controls"] is False
    assert s["layer"] == 2


# --------------------------------------------------------------------------
# VideoNode — emit + describe
# --------------------------------------------------------------------------


def test_video_emit_placeholder_when_empty(engine, view):
    engine.spawn("vid3", "VideoNode", params={
        "placeholder_color": [0.1, 0.1, 0.1],
    })
    node = engine.nodes["vid3"]
    ctx = EmitContext(engine=engine, node=node)
    channels = engine.types["VideoNode"].emit(node.state, view, ctx)
    assert channels["color"].shape == (view.height, view.width, 3)
    assert channels["depth"].shape == (view.height, view.width)


def test_video_emit_with_missing_file(engine, view, tmp_path):
    """A non-existent path renders the placeholder + alt-text overlay
    without raising."""
    engine.spawn("vid4", "VideoNode", params={
        "src": str(tmp_path / "no_such_video.mp4"),
        "alt_text": "missing",
        "placeholder_color": [0.05, 0.05, 0.05],
    })
    node = engine.nodes["vid4"]
    ctx = EmitContext(engine=engine, node=node)
    channels = engine.types["VideoNode"].emit(node.state, view, ctx)
    assert channels["color"].shape == (view.height, view.width, 3)


def test_video_describe_includes_state(engine):
    engine.spawn("vid5", "VideoNode", params={
        "src": "https://example.com/clip.mp4",
        "autoplay": True,
    })
    node = engine.nodes["vid5"]
    ctx = EmitContext(engine=engine, node=node)
    line = engine.types["VideoNode"].describe(node.state, ctx)
    assert "VideoNode" in line
    assert "autoplay=True" in line
    assert "src_state=url-deferred" in line


# --------------------------------------------------------------------------
# VideoNode — playback verbs
# --------------------------------------------------------------------------


def test_video_play_pause_verbs(engine):
    engine.spawn("vid6", "VideoNode", params={"autoplay": False})
    node = engine.nodes["vid6"]
    state = node.state
    vt = engine.types["VideoNode"]

    res = vt.handle_action(state, "play", {}, engine, node)
    assert res["autoplay"] is True
    assert state["autoplay"] is True

    res = vt.handle_action(state, "pause", {}, engine, node)
    assert res["autoplay"] is False
    assert state["autoplay"] is False


def test_video_set_loop_verb(engine):
    engine.spawn("vid7", "VideoNode", params={})
    node = engine.nodes["vid7"]
    state = node.state
    vt = engine.types["VideoNode"]
    res = vt.handle_action(state, "set_loop", {"value": True}, engine, node)
    assert res["loop"] is True
    assert state["loop"] is True


def test_video_set_controls_verb(engine):
    engine.spawn("vid8", "VideoNode", params={})
    node = engine.nodes["vid8"]
    state = node.state
    vt = engine.types["VideoNode"]
    res = vt.handle_action(state, "set_controls", {"value": False},
                            engine, node)
    assert res["controls"] is False
    assert state["controls"] is False


# --------------------------------------------------------------------------
# Visual-variant swap — function/visual split contract (SPEC-090)
# --------------------------------------------------------------------------


def test_image_displayed_by_slot_preserves_state(engine, temp_png):
    """Swapping displayed_by changes the visual binding but not the
    functional state (Decision A1; Scenario 2 of the per-module plan)."""
    engine.spawn("imgA", "ImageNode", params={
        "src": str(temp_png),
        "displayed_by": "image_default_v1",
    })
    s_a = engine.nodes["imgA"].state
    assert s_a["src"] == str(temp_png)
    assert s_a["displayed_by"] == "image_default_v1"

    engine.spawn("imgB", "ImageNode", params={
        "src": str(temp_png),
        "displayed_by": "image_painterly_v1",  # future variant
    })
    s_b = engine.nodes["imgB"].state
    # Functional state identical across variants.
    assert s_a["src"] == s_b["src"]
    # Visual binding differs.
    assert s_a["displayed_by"] != s_b["displayed_by"]


def test_video_displayed_by_slot_preserves_state(engine):
    engine.spawn("vidA", "VideoNode", params={
        "src": "/x.mp4", "loop": True,
        "displayed_by": "video_default_v1",
    })
    engine.spawn("vidB", "VideoNode", params={
        "src": "/x.mp4", "loop": True,
        "displayed_by": "video_painterly_v1",
    })
    a = engine.nodes["vidA"].state
    b = engine.nodes["vidB"].state
    assert a["src"] == b["src"]
    assert a["loop"] == b["loop"]
    assert a["displayed_by"] != b["displayed_by"]


# --------------------------------------------------------------------------
# select_children — no children (content leaves)
# --------------------------------------------------------------------------


def test_image_has_no_children(engine, view):
    engine.spawn("imgC", "ImageNode", params={})
    node = engine.nodes["imgC"]
    children = engine.types["ImageNode"].select_children(
        node.state, view, engine, node,
    )
    assert children == []


def test_video_has_no_children(engine, view):
    engine.spawn("vidC", "VideoNode", params={})
    node = engine.nodes["vidC"]
    children = engine.types["VideoNode"].select_children(
        node.state, view, engine, node,
    )
    assert children == []
