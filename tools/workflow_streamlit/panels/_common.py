"""Shared types for the panel contract.

Every panel under ``panels/`` exposes two callables that mirror Apeiron's
node-type contract:

- ``manifest() -> PanelManifest`` — pure data; the registry reads this at
  discovery time to know where the panel mounts and what data it needs.
- ``render(ctx: PanelContext) -> None`` — actually draws via streamlit
  primitives. The driver calls this once per autorefresh tick.

Keeping ``manifest`` pure makes the registry safe to introspect even
when ``streamlit`` is not importable (e.g. headless tests). Renderers
other than Streamlit consume the same manifest and bring their own
``render`` adapters.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

# Mount points. The driver mounts each registered panel into exactly one.
MOUNT_SIDEBAR = "sidebar"
MOUNT_MAIN = "main"
MOUNT_BOTTOM = "bottom"
MOUNT_GATE = "gate"   # special: renders BEFORE auth completes; can short-circuit


@dataclass
class PanelManifest:
    name: str
    description: str
    mount_point: str = MOUNT_MAIN
    order: int = 100   # lower numbers render first within a mount point
    requires_auth: bool = True
    hidden: bool = False


@dataclass
class PanelContext:
    """What every panel sees. The runtime fills these in before each render."""
    engine: Any                     # engine.core.Engine
    session_manager: Any            # tools.workflow.session_manager.SessionManager
    inbox: Any                      # tools.workflow.inbox.Inbox
    file_watcher: Any               # engine.file_watcher.FileWatcher
    config: Any                     # tools.workflow_streamlit.config.RuntimeConfig
    apeiron_root: Path
    user: Optional[str] = None      # authenticated username (None until auth)
    active_session_id: Optional[str] = None
    # Per-rerun scratchpad — never persists across reruns.
    scratch: dict = field(default_factory=dict)

    def as_command_context(self):
        """Build a ``CommandContext`` that mirrors this PanelContext.

        The scratch dict is shared by reference so handlers and panels
        can pass state through it within a single rerun (e.g. a
        ``scene.load`` handler writes ``current_scene`` and the scene
        picker reads it back in the same tick).
        """
        from tools.workflow_streamlit.command_registry import CommandContext
        return CommandContext(
            engine=self.engine,
            session_manager=self.session_manager,
            inbox=self.inbox,
            file_watcher=self.file_watcher,
            config=self.config,
            apeiron_root=self.apeiron_root,
            active_session_id=self.active_session_id,
            user=self.user,
            scratch=self.scratch,
        )
