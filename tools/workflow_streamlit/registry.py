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
