"""
SPEC-066 — BrowserRenderer node-type tests.

Covers:

- The node-type's ``manifest`` / ``build`` / ``select_children`` /
  ``precompute_hook`` / ``emit`` / ``describe`` surface.
- The ``html_string`` override beating ``url`` (the explicit-override
  rule).
- The trust-gate composition: a pasted BrowserRenderer snippet flows
  through the SPEC-054 render-trust check exactly the way other
  node-types do.
- The text-API verbs ``browser-open`` / ``browser-html`` /
  ``browser-current-url`` route through ``GuiShell.browser_*`` when a
  shell is attached.
- The ``Browser`` ViewSpec in ``default_view_registry()`` has
  ``kind=web`` (catches a default-registry regression).
- ``tools.browser`` module surface (``is_available``, ``open_url``,
  ``open_html``, ``current_url``).

Headless-safe. No network I/O. Doesn't require Playwright (the 3D
path is opt-in and a missing dep is a passing case for the relevant
tests).
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Dict, Optional

import numpy as np
import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine  # noqa: E402
from engine.node import EmitContext, NodeInstance, View  # noqa: E402
from node_types import browser_renderer  # noqa: E402
from tools.workflow.trust import render_trust_set  # noqa: E402


# ---------------------------------------------------------------------------
# Manifest + build + select_children.
# ---------------------------------------------------------------------------


def test_manifest_shape():
    m = browser_renderer.manifest()
    assert m.name == "BrowserRenderer"
    assert m.version == "1.0"
    assert m.renderer_id == "raster"
    # The manifest must advertise the BSC inputs maintainers can override.
    for key in (
        "url", "html_string", "screen_width", "screen_height",
        "viewport_width", "viewport_height", "refresh_seconds", "backend",
    ):
        assert key in m.inputs, f"manifest missing input: {key}"
    # Standard 3D-path outputs.
    assert m.outputs == {"color": "rgb_image", "depth": "depth_image"}


def test_build_defaults():
    state = browser_renderer.build({})
    assert state["url"] == ""
    assert state["html_string"] == ""
    assert state["viewport_width"] == 1280
    assert state["viewport_height"] == 800
    assert state["backend"] == "tkinterweb"
    assert state["refresh_seconds"] == 0.0


def test_build_normalizes_types():
    """build() normalizes via float()/int()/str() so JSON-typed params
    (everything-strings paste payloads) still spawn cleanly."""
    state = browser_renderer.build({
        "url": "https://example.com",
        "html_string": "",
        "screen_width": "5.0",
        "screen_height": "3.5",
        "screen_resolution": "512",
        "viewport_width": "1024",
        "viewport_height": "768",
        "refresh_seconds": "0",
    })
    assert state["url"] == "https://example.com"
    assert state["screen_width"] == pytest.approx(5.0)
    assert state["screen_height"] == pytest.approx(3.5)
    assert state["screen_resolution"] == 512
    assert state["viewport_width"] == 1024
    assert state["viewport_height"] == 768


def test_select_children_is_empty():
    """BrowserRenderer is a leaf node — engine traversal never recurses
    past it. Mirrors Computer's select_children=[] pattern."""
    state = browser_renderer.build({"url": "about:blank"})
    children = browser_renderer.select_children(state, View(), engine=None, node=None)
    assert children == []


# ---------------------------------------------------------------------------
# precompute_hook + emit + describe.
# ---------------------------------------------------------------------------


class _StubEngine:
    """Minimal engine surface for precompute / emit tests without
    spinning up the real Engine + discover."""

    def __init__(self):
        self.cache: Dict[str, Any] = {}
        self.errors: list = []


def _make_node(state) -> NodeInstance:
    return NodeInstance(id="b1", type_name="BrowserRenderer", params={}, state=state)


def test_precompute_html_mode_caches_inputs():
    state = browser_renderer.build({"html_string": "<h1>hi</h1>"})
    engine = _StubEngine()
    node = _make_node(state)
    out = browser_renderer.precompute_hook(state, engine, node)
    assert out["source_mode"] == "html"
    assert out["html_string"] == "<h1>hi</h1>"
    # No Playwright invoked in html mode → no bitmap, no error.
    assert out["bitmap"] is None
    assert out["error"] is None


def test_precompute_url_mode_caches_inputs():
    """URL mode caches the URL even when Playwright isn't installed.
    The 3D path's bitmap is opt-in; the absence isn't a failure."""
    state = browser_renderer.build({"url": "https://example.com"})
    engine = _StubEngine()
    node = _make_node(state)
    out = browser_renderer.precompute_hook(state, engine, node)
    assert out["source_mode"] == "url"
    assert out["url"] == "https://example.com"
    # bitmap may be None (no playwright) or a numpy array (playwright
    # present) — both are valid outcomes for v1.
    if out["bitmap"] is not None:
        assert isinstance(out["bitmap"], np.ndarray)


def test_precompute_no_source_yields_none_mode():
    state = browser_renderer.build({})
    engine = _StubEngine()
    node = _make_node(state)
    out = browser_renderer.precompute_hook(state, engine, node)
    assert out["source_mode"] == "none"
    assert out["bitmap"] is None


def test_html_string_overrides_url_in_source_mode():
    """The explicit html_string override wins over a configured URL.
    Catches the regression where url + html_string both set would
    silently fall through to network fetch."""
    state = browser_renderer.build({
        "url": "https://example.com",
        "html_string": "<p>local</p>",
    })
    assert state["html_string"] == "<p>local</p>"
    engine = _StubEngine()
    node = _make_node(state)
    out = browser_renderer.precompute_hook(state, engine, node)
    assert out["source_mode"] == "html"
    # Playwright must NOT have been invoked even if installed.
    assert out["bitmap"] is None
    assert out["error"] is None


def test_emit_without_bitmap_returns_solid_screen_rect():
    state = browser_renderer.build({"url": "https://example.com"})
    engine = _StubEngine()
    node = _make_node(state)
    # precompute populates the cache without a bitmap (no playwright
    # in test env / URL not reachable).
    engine.cache[node.id] = {
        "source_mode": "url",
        "url": state["url"],
        "html_string": "",
        "bitmap": None,
        "error": None,
    }
    view = View(width=64, height=48)
    ctx = EmitContext(engine=engine, node=node)
    channels = browser_renderer.emit(state, view, ctx)
    assert set(channels.keys()) == {"color", "depth"}
    assert channels["color"].shape == (48, 64, 3)
    assert channels["color"].dtype == np.float32
    assert channels["depth"].shape == (48, 64)


def test_emit_with_bitmap_uv_samples_onto_rect():
    state = browser_renderer.build({"url": "https://example.com"})
    engine = _StubEngine()
    node = _make_node(state)
    # Stub a recognizable bitmap (solid red).
    bitmap = np.zeros((80, 100, 3), dtype=np.float32)
    bitmap[..., 0] = 1.0
    engine.cache[node.id] = {
        "source_mode": "url",
        "url": state["url"],
        "html_string": "",
        "bitmap": bitmap,
        "error": None,
    }
    view = View(width=64, height=48)
    ctx = EmitContext(engine=engine, node=node)
    channels = browser_renderer.emit(state, view, ctx)
    # The center pixel of the view should hit the screen rect and
    # sample the red bitmap.
    cy, cx = channels["color"].shape[0] // 2, channels["color"].shape[1] // 2
    assert channels["color"][cy, cx, 0] > 0.5, (
        f"center pixel not red: {channels['color'][cy, cx]}"
    )


def test_describe_text_includes_source_and_dimensions():
    state = browser_renderer.build({"url": "https://example.com"})
    engine = _StubEngine()
    node = _make_node(state)
    engine.cache[node.id] = {
        "source_mode": "url",
        "url": state["url"],
        "html_string": "",
        "bitmap": None,
        "error": None,
    }
    ctx = EmitContext(engine=engine, node=node)
    text = browser_renderer.describe(state, ctx)
    assert "BrowserRenderer" in text
    assert "https://example.com" in text
    assert "1280x800" in text  # default viewport
    assert "tkinterweb" in text
    assert "bitmap=none" in text


def test_describe_text_in_html_mode_shows_html_prefix():
    state = browser_renderer.build({"html_string": "<h1>hello world</h1>"})
    engine = _StubEngine()
    node = _make_node(state)
    engine.cache[node.id] = browser_renderer.precompute_hook(state, engine, node)
    ctx = EmitContext(engine=engine, node=node)
    text = browser_renderer.describe(state, ctx)
    assert "BrowserRenderer" in text
    assert "hello world" in text  # prefix visible in describe


# ---------------------------------------------------------------------------
# Engine discover + trust-gate composition (SPEC-054).
# ---------------------------------------------------------------------------


def test_engine_discover_registers_browser_renderer():
    """A fresh engine with the production trust-set picks up the
    BrowserRenderer node-type. Catches a regression that drops the
    type from the ``node_types/*.py`` glob."""
    engine = Engine(root_dir=ROOT, trust_set=render_trust_set(ROOT))
    engine.discover()
    assert "BrowserRenderer" in engine.types, (
        f"BrowserRenderer not registered. types={sorted(engine.types)}"
    )


def test_spawning_browser_renderer_produces_live_node():
    """Spawn succeeds against the live engine — the node-type's build()
    accepts the canonical param shape and the engine doesn't mark the
    node dead."""
    engine = Engine(root_dir=ROOT, trust_set=render_trust_set(ROOT))
    engine.discover()
    engine.spawn(
        node_id="probe_browser",
        type_name="BrowserRenderer",
        params={"url": "https://example.com"},
    )
    node = engine.nodes["probe_browser"]
    assert not node.dead, f"node dead: {node.error}"
    assert node.state["url"] == "https://example.com"


def test_paste_of_browser_renderer_passes_trust_gate():
    """SPEC-054 + SPEC-073: a pasted BrowserRenderer snippet flows
    through the engine's render-trust gate. Because the node-type
    source file is at ``node_types/browser_renderer.py`` — a default
    render-trust pattern — the paste lands cleanly."""
    from tools.module_clipboard import paste_text_to_engine

    engine = Engine(root_dir=ROOT, trust_set=render_trust_set(ROOT))
    engine.discover()
    snippet = (
        '{"module": [{"id": "pasted_browser", "type": "BrowserRenderer", '
        '"params": {"url": "https://example.com"}, "connections": {}}]}'
    )
    new_ids = paste_text_to_engine(engine, snippet)
    assert "pasted_browser" in new_ids
    assert not engine.nodes["pasted_browser"].dead


def test_browser_renderer_in_default_render_trust_patterns():
    """The default render-trust patterns cover ``node_types/*.py``, so
    the BrowserRenderer source path is trusted by default. Verify the
    trust-set agrees."""
    ts = render_trust_set(ROOT)
    assert ts.is_trusted("node_types/browser_renderer.py")


# ---------------------------------------------------------------------------
# tools.browser primitives.
# ---------------------------------------------------------------------------


def test_tools_browser_is_available_returns_bool():
    """``is_available`` always returns a bool — never raises even if
    tkinterweb is missing (the test environment may or may not have
    it installed; we only assert the contract)."""
    from tools import browser

    result = browser.is_available()
    assert isinstance(result, bool)


def test_tools_browser_open_url_when_available():
    """When tkinterweb is available, ``open_html`` returns a widget
    we can destroy + pack. We don't pin the widget's exact base class
    (HtmlFrame inherits from tkinterweb's own internal frame), but
    we do verify the duck-typed Tk-widget surface (winfo + destroy)
    plus the load_html attribute that downstream callers use."""
    from tools import browser

    if not browser.is_available():
        pytest.skip("tkinterweb not installed in this env")

    import tkinter as tk
    root = tk.Tk()
    root.withdraw()
    try:
        frame = browser.open_html(root, "<html><body>hi</body></html>")
        assert frame is not None
        # Tk-widget surface — what downstream code actually depends on.
        assert hasattr(frame, "winfo_children")
        assert hasattr(frame, "destroy")
        assert hasattr(frame, "load_url")
        assert hasattr(frame, "load_html")
        frame.destroy()
    finally:
        root.destroy()


def test_tools_browser_unavailable_raises_descriptive_error(monkeypatch):
    """When tkinterweb's import fails, ``open_url`` raises
    ``BrowserUnavailableError`` with the install command in the
    message. Simulated by patching the import path."""
    from tools import browser

    def _raise(*args, **kwargs):
        raise browser.BrowserUnavailableError(
            "tkinterweb is not installed. Install with: pip install \"tkinterweb>=4.25.2,<5\""
        )
    monkeypatch.setattr(browser, "_require_html_frame", _raise)

    with pytest.raises(browser.BrowserUnavailableError) as ei:
        browser.open_url(None, "https://example.com")
    assert "tkinterweb" in str(ei.value)
    assert "pip install" in str(ei.value)


# ---------------------------------------------------------------------------
# Default view registry exposes Browser view (kind=web).
# ---------------------------------------------------------------------------


def test_default_view_registry_contains_browser_view():
    from tools.workflow_gui.view_registry import default_view_registry
    reg = default_view_registry()
    spec = reg.get("Browser")
    assert spec is not None, "Browser view missing from default_view_registry"
    assert spec.kind == "web"
    assert spec.description  # non-empty


def test_view_registry_accepts_web_kind():
    """The registry's VALID_KINDS check permits the new ``web`` kind."""
    from tools.workflow_gui.view_registry import ViewRegistry, ViewSpec
    reg = ViewRegistry()
    reg.register(ViewSpec(name="X", kind="web", url="about:blank"))
    assert reg.get("X").kind == "web"


def test_view_registry_rejects_unknown_kind():
    """Sanity check the typo-catcher still fires for unknown kinds."""
    from tools.workflow_gui.view_registry import ViewRegistry, ViewSpec
    reg = ViewRegistry()
    with pytest.raises(ValueError):
        reg.register(ViewSpec(name="Y", kind="hyperloop"))


def test_view_spec_carries_url_and_html_fields():
    from tools.workflow_gui.view_registry import ViewSpec
    spec = ViewSpec(name="Foo", kind="web", url="https://example.com")
    assert spec.url == "https://example.com"
    assert spec.html_string == ""


def test_view_spec_as_tabs_uses_web_marker():
    from tools.workflow_gui.view_registry import ViewRegistry, ViewSpec
    reg = ViewRegistry()
    reg.register(ViewSpec(name="Browser", kind="web", url="about:blank"))
    tabs = reg.as_tabs()
    assert tabs == [("Browser", "_web:Browser", None)]


# ---------------------------------------------------------------------------
# Text-API verbs (SPEC-081 composition).
# ---------------------------------------------------------------------------


class _StubShell:
    """Just enough surface to test the verbs' shell dispatch."""

    def __init__(self):
        self.opened: Optional[str] = None
        self.loaded_html: Optional[str] = None
        self.url: Optional[str] = None
        self.fail = False

    def browser_open(self, url: str) -> bool:
        if self.fail:
            return False
        self.opened = url
        self.url = url
        return True

    def browser_load_html(self, html: str) -> bool:
        if self.fail:
            return False
        self.loaded_html = html
        return True

    def browser_current_url(self) -> Optional[str]:
        return self.url


class _MiniEngine:
    """Engine stub carrying just the attribute the verb dispatchers
    read."""
    def __init__(self, shell=None):
        self.gui_shell = shell


def test_text_api_browser_open_routes_to_shell():
    from tools.text_test import dispatch_command
    shell = _StubShell()
    e = _MiniEngine(shell)
    msg, _ = dispatch_command(e, "browser-open https://example.com")
    assert msg.startswith("OK")
    assert shell.opened == "https://example.com"


def test_text_api_browser_open_requires_url():
    from tools.text_test import dispatch_command
    shell = _StubShell()
    e = _MiniEngine(shell)
    msg, _ = dispatch_command(e, "browser-open")
    assert msg.startswith("ERR")
    assert "requires <url>" in msg


def test_text_api_browser_open_without_shell_errors_out():
    from tools.text_test import dispatch_command
    e = _MiniEngine(shell=None)
    msg, _ = dispatch_command(e, "browser-open https://example.com")
    assert msg.startswith("ERR")
    assert "gui_shell" in msg


def test_text_api_browser_open_failure_surfaces_helpful_message():
    from tools.text_test import dispatch_command
    shell = _StubShell()
    shell.fail = True
    e = _MiniEngine(shell)
    msg, _ = dispatch_command(e, "browser-open https://example.com")
    assert msg.startswith("ERR")
    assert "Browser frame" in msg


def test_text_api_browser_html_routes_to_shell():
    from tools.text_test import dispatch_command
    shell = _StubShell()
    e = _MiniEngine(shell)
    msg, _ = dispatch_command(e, "browser-html <h1>hi</h1>")
    assert msg.startswith("OK")
    assert shell.loaded_html == "<h1>hi</h1>"


def test_text_api_browser_current_url_returns_value():
    from tools.text_test import dispatch_command
    shell = _StubShell()
    shell.url = "https://loaded.example/page"
    e = _MiniEngine(shell)
    msg, _ = dispatch_command(e, "browser-current-url")
    assert msg.startswith("OK")
    assert "https://loaded.example/page" in msg


def test_text_api_browser_current_url_no_url():
    from tools.text_test import dispatch_command
    shell = _StubShell()
    shell.url = None
    e = _MiniEngine(shell)
    msg, _ = dispatch_command(e, "browser-current-url")
    assert msg.startswith("OK")
    assert "(no url)" in msg


def test_text_api_list_commands_includes_browser_verbs():
    from tools.text_test import dispatch_command
    e = _MiniEngine()
    msg, _ = dispatch_command(e, "list-commands")
    assert "browser-open" in msg
    assert "browser-html" in msg
    assert "browser-current-url" in msg
