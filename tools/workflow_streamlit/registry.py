"""Panel discovery — walks ``panels/`` and surfaces every (manifest, render) pair.

Mirrors the discovery pattern of ``engine.core.Engine.discover`` (which
walks ``node_types/`` and ``renderers/``) so the Streamlit-side surface
inherits the same one-file-per-component property the engine has. The
file-watcher does not yet hot-reload Streamlit panels — Streamlit's own
script-rerun handles that — but the contract is structurally the same.

A panel module that fails to import is skipped with a logged warning;
the rest of the surface keeps working. Matches the engine's try/except
isolation: one broken panel never blocks the others.
"""

from __future__ import annotations

import importlib.util
import sys
import traceback
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from .panels._common import PanelContext, PanelManifest


@dataclass
class RegisteredPanel:
    manifest: PanelManifest
    render: Callable[[PanelContext], None]
    source_path: Path
    load_error: Optional[str] = None


PANELS_DIR = Path(__file__).resolve().parent / "panels"


def discover_panels(panels_dir: Path = PANELS_DIR) -> List[RegisteredPanel]:
    """Discover every ``panels/<name>.py`` module.

    Names beginning with ``_`` (like ``_common.py``) and ``__init__.py``
    are skipped — the underscore prefix marks "internal, not a panel"
    the same way Python uses it for private modules.
    """
    out: List[RegisteredPanel] = []
    if not panels_dir.exists():
        return out
    for py in sorted(panels_dir.glob("*.py")):
        if py.name == "__init__.py" or py.name.startswith("_"):
            continue
        try:
            module = _import_panel_module(py)
            manifest = module.manifest()
            render = module.render
        except Exception as exc:
            tb = traceback.format_exc(limit=3)
            placeholder = PanelManifest(
                name=py.stem,
                description=f"panel failed to load: {exc}",
                hidden=True,
            )
            out.append(
                RegisteredPanel(
                    manifest=placeholder,
                    render=_error_render(py.name, exc, tb),
                    source_path=py,
                    load_error=f"{exc}\n{tb}",
                )
            )
            continue
        if not isinstance(manifest, PanelManifest):
            continue
        if manifest.hidden:
            continue
        out.append(
            RegisteredPanel(
                manifest=manifest,
                render=render,
                source_path=py,
                load_error=None,
            )
        )
    return out


def discover_panels_with_engine_overrides(
    engine: Any,
    panels_dir: Path = PANELS_DIR,
) -> List[RegisteredPanel]:
    """Discover filesystem panels + apply scene-declared overrides.

    Walks ``panels/`` for every panel module (the existing path), then
    walks ``engine.nodes`` for every ``StreamlitPanel`` instance and
    applies the scene's overrides on top of the panel module's own
    manifest. A panel declared in the scene with explicit mount_point
    or order wins over the panel's PanelManifest defaults.

    A panel module that the scene does NOT declare is still discovered
    and rendered with its own defaults — declarative-scene is additive,
    not exclusive, so the existing surface keeps working untouched.

    A scene declaration whose panel_name does not match any panel
    module is recorded as a hidden RegisteredPanel with a load_error so
    the driver can surface the mismatch without crashing.

    Closes the parallel-registry gap from the 2026-05-21 audit
    (criterion 2). The deeper lift — moving panels into ``node_types/``
    entirely — is a follow-up; this function is the bridge.
    """
    panels = discover_panels(panels_dir=panels_dir)
    by_name = {p.manifest.name: p for p in panels}

    # Walk engine.nodes for StreamlitPanel instances and apply overrides.
    nodes = getattr(engine, "nodes", {}) or {}
    for node_id, instance in nodes.items():
        if getattr(instance, "type_name", None) != "StreamlitPanel":
            continue
        state = getattr(instance, "state", {}) or {}
        panel_name = (state.get("panel_name") or "").strip()
        if not panel_name:
            continue
        match = by_name.get(panel_name)
        if match is None:
            # Scene declares a panel the filesystem doesn't carry.
            # Record it as a hidden + load-errored entry so the driver
            # can show the mismatch without crashing.
            placeholder = PanelManifest(
                name=panel_name,
                description=(
                    f"scene declared StreamlitPanel '{node_id}' with "
                    f"panel_name='{panel_name}' but no matching panel "
                    f"module exists under panels/"
                ),
                hidden=True,
            )
            panels.append(
                RegisteredPanel(
                    manifest=placeholder,
                    render=_error_render(
                        f"{panel_name} (scene)",
                        ValueError(f"unknown panel_name {panel_name!r}"),
                        f"scene node {node_id} declared this panel",
                    ),
                    source_path=Path(f"<scene:{node_id}>"),
                    load_error=f"unknown panel_name {panel_name!r}",
                )
            )
            continue

        # Apply scene-declared overrides on top of the module's manifest.
        override_mount = state.get("mount_point")
        override_order = state.get("order")
        override_hidden = state.get("hidden")
        if (
            override_mount is None
            and override_order is None
            and not override_hidden
        ):
            continue  # nothing to override
        new_manifest = PanelManifest(
            name=match.manifest.name,
            description=match.manifest.description,
            mount_point=(
                override_mount
                if override_mount
                else match.manifest.mount_point
            ),
            order=(
                int(override_order)
                if override_order is not None
                else match.manifest.order
            ),
            requires_auth=match.manifest.requires_auth,
            hidden=bool(override_hidden) or match.manifest.hidden,
        )
        # Replace the match in-place to preserve list ordering.
        idx = panels.index(match)
        panels[idx] = RegisteredPanel(
            manifest=new_manifest,
            render=match.render,
            source_path=match.source_path,
            load_error=match.load_error,
        )
        by_name[match.manifest.name] = panels[idx]
    return panels


def _import_panel_module(path: Path) -> Any:
    """Fresh-import a panel module under a stable name."""
    mod_name = f"apeiron_workflow_streamlit_panels_{path.stem}"
    if mod_name in sys.modules:
        del sys.modules[mod_name]
    spec = importlib.util.spec_from_file_location(mod_name, str(path))
    if spec is None or spec.loader is None:
        raise ImportError(f"could not load spec for {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[mod_name] = module
    spec.loader.exec_module(module)
    return module


def _error_render(filename: str, exc: Exception, tb: str) -> Callable[[PanelContext], None]:
    def _render(ctx: PanelContext) -> None:
        import streamlit as st
        st.error(f"Panel `{filename}` failed to load: {exc}")
        with st.expander("traceback"):
            st.code(tb)
    return _render


def panels_for_mount(
    panels: List[RegisteredPanel], mount_point: str
) -> List[RegisteredPanel]:
    """Filter + order panels for a given mount point."""
    return sorted(
        (p for p in panels if p.manifest.mount_point == mount_point),
        key=lambda p: (p.manifest.order, p.manifest.name),
    )
