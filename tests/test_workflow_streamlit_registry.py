"""Headless tests for the Streamlit workflow panel registry.

These tests do NOT import ``streamlit`` (which is only needed at render
time); they exercise the discovery + manifest contract in isolation so
that "panels load cleanly" is a fast-running check independent of any
browser harness.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from tools.workflow_streamlit.panels._common import (
    MOUNT_BOTTOM,
    MOUNT_GATE,
    MOUNT_MAIN,
    MOUNT_SIDEBAR,
    PanelManifest,
)
from tools.workflow_streamlit.registry import (
    PANELS_DIR,
    RegisteredPanel,
    discover_panels,
    panels_for_mount,
)


def test_discover_returns_at_least_the_known_panels():
    panels = discover_panels()
    names = {p.manifest.name for p in panels}
    # The shipped surface — auth, session-status, scene-picker, idea-queue,
    # workflow-view, chat. The internal ``items`` helper module declares
    # itself ``hidden=True`` and the registry filters it out.
    expected = {
        "auth",
        "session-status",
        "scene-picker",
        "idea-queue",
        "workflow-view",
        "chat",
    }
    assert expected.issubset(names), f"missing panels: {expected - names}"


def test_every_discovered_panel_has_a_valid_mount_point():
    panels = discover_panels()
    valid = {MOUNT_GATE, MOUNT_SIDEBAR, MOUNT_MAIN, MOUNT_BOTTOM}
    for p in panels:
        assert p.manifest.mount_point in valid, (
            f"panel {p.manifest.name} has invalid mount_point "
            f"{p.manifest.mount_point!r}"
        )


def test_panels_for_mount_filters_and_orders():
    """Panels at a mount point come back ordered by ``order`` ascending."""
    panels = discover_panels()
    sidebar = panels_for_mount(panels, MOUNT_SIDEBAR)
    orders = [p.manifest.order for p in sidebar]
    assert orders == sorted(orders), f"sidebar panels not ordered: {orders}"


def test_failed_panel_does_not_break_discovery(tmp_path):
    """A broken panel file in the panels dir surfaces as a load_error
    placeholder rather than crashing the registry."""
    fake_dir = tmp_path / "panels"
    fake_dir.mkdir()
    # One healthy panel.
    good = fake_dir / "good.py"
    good.write_text(
        "from tools.workflow_streamlit.panels._common import MOUNT_MAIN, PanelManifest\n"
        "def manifest():\n"
        "    return PanelManifest(name='good', description='ok', mount_point=MOUNT_MAIN)\n"
        "def render(ctx):\n"
        "    pass\n",
        encoding="utf-8",
    )
    # One broken panel that raises on import.
    bad = fake_dir / "bad.py"
    bad.write_text("raise RuntimeError('intentional')\n", encoding="utf-8")

    panels = discover_panels(panels_dir=fake_dir)
    by_name = {p.manifest.name: p for p in panels}
    # The healthy panel loads cleanly.
    assert "good" in by_name and by_name["good"].load_error is None
    # The broken panel surfaces as a registered placeholder with
    # ``load_error`` set, so the driver can render an error card. The
    # placeholder's manifest is ``hidden=True``; the driver decides
    # whether to filter or display.
    assert "bad" in by_name
    bad = by_name["bad"]
    assert bad.load_error is not None and "intentional" in bad.load_error
    assert bad.manifest.hidden is True
    # And critically — discovery did not raise.


def test_manifest_dataclass_defaults_are_sane():
    m = PanelManifest(name="x", description="y")
    assert m.mount_point == MOUNT_MAIN
    assert m.order == 100
    assert m.requires_auth is True
    assert m.hidden is False


def test_registry_panels_dir_points_at_actual_panels_dir():
    """Sanity check that the registry's default is the package's panels/."""
    assert PANELS_DIR.exists() and PANELS_DIR.is_dir()
    assert (PANELS_DIR / "_common.py").exists()
