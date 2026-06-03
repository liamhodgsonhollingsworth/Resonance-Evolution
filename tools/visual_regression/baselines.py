"""
SPEC-069 phase 2+3 baseline registry — wires the canonical GUI views
into ``tools.visual_regression`` so the SSIM safety net detects palette
or typography drift introduced by future edits.

Three baselines ship as part of the phase 2+3 migration:

- ``tasks_tab_default`` — GuiShell on the Tasks tab with the default
  panel layout.
- ``inbox_tab_default`` — GuiShell on the Inbox tab.
- ``chat_tab_default`` — GuiShell on the Chat tab.

Each renderer hook constructs a real ``GuiShell`` against the stub
engine/session-manager/inbox surfaces ``tools.gui_test_driver`` exposes,
calls ``build_ui()`` to produce a Tk root, drives the shell to the
named tab, pumps the event loop, and returns the toplevel widget for
``capture_widget()`` to grab. Capture must run with a real display
(Windows OK; Linux needs ``$DISPLAY``); the runner reports
``headless`` cleanly otherwise.

The PNG baselines live at
``tests/visual_regression/baselines/<name>.png``. Phase 2+3 establishes
them via ``visual-regression-capture <name>`` for each registered
view. Future edits that drift the palette or typography fail the
SSIM comparison; cosmetic drift > SSIM 0.85 is the spec'd tolerance.

The module is import-side-effect-free — call ``register_phase23_baselines()``
once on first use (or via the ``visual-regression-list`` text-API verb,
which calls into ``default_manifest()``).
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Callable

from tools.visual_regression.manifest import (
    BaselineManifest,
    BaselineSpec,
    default_manifest,
)


# SSIM tolerance for phase 2+3 baselines. The maintainer's spec sets
# 0.85 as the cosmetic-change floor (a palette migration WILL drop
# SSIM below the default 0.98; 0.85 is the post-migration sanity
# bound that catches a major regression while allowing for the
# expected color shift).
PHASE_23_SSIM_THRESHOLD = 0.85


_TARGET_GEOMETRY = "640x480+50+50"


def _build_shell_for_tab(tab_name: str) -> Any:
    """Spin up a real GuiShell, build the UI, navigate to ``tab_name``,
    and return the Tk root widget for capture.

    Imports are lazy so this module loads even when Tk isn't
    available.
    """
    # Use the stub backends from gui_test_driver — they let the shell
    # build without a real engine/inbox/session-manager.
    from tools.gui_test_driver import (
        _StubEngine,
        _StubInbox,
        _StubSessionManager,
    )
    from tools.workflow_gui.gui_shell import GuiShell

    cache = {
        "wishes_source": {
            "items": [
                {
                    "id": "demo-1",
                    "title": "Demo task",
                    "body": "Sample task body for the visual baseline.",
                    "status": "pending",
                    "actions": ["expand", "archive"],
                },
            ],
        },
    }
    shell = GuiShell(
        engine=_StubEngine(cache=cache),
        session_manager=_StubSessionManager(records=[]),
        inbox=_StubInbox(messages=[]),
        root=Path("."),
        scene_path=None,
        scene_root_id=None,
        current_user=None,
    )
    shell.build_ui()
    if shell.tk_root is not None:
        # Fix the window geometry so baselines have a stable size.
        try:
            shell.tk_root.geometry(_TARGET_GEOMETRY)
        except Exception:
            pass
    shell.select_tab(tab_name)
    if shell.tk_root is not None:
        try:
            shell.tk_root.update_idletasks()
            shell.tk_root.update()
        except Exception:
            pass
    return shell.tk_root


def _tasks_renderer() -> Any:
    return _build_shell_for_tab("Tasks")


def _inbox_renderer() -> Any:
    return _build_shell_for_tab("Inbox")


def _chat_renderer() -> Any:
    return _build_shell_for_tab("Chat")


PHASE_23_BASELINES: list[BaselineSpec] = [
    BaselineSpec(
        name="tasks_tab_default",
        renderer=_tasks_renderer,
        description=(
            "GuiShell on the Tasks tab with default panel layout. "
            "SPEC-069 phase 2+3 baseline."
        ),
        threshold=PHASE_23_SSIM_THRESHOLD,
        tags=("2d", "spec-069", "phase-2-3"),
    ),
    BaselineSpec(
        name="inbox_tab_default",
        renderer=_inbox_renderer,
        description=(
            "GuiShell on the Inbox tab. SPEC-069 phase 2+3 baseline."
        ),
        threshold=PHASE_23_SSIM_THRESHOLD,
        tags=("2d", "spec-069", "phase-2-3"),
    ),
    BaselineSpec(
        name="chat_tab_default",
        renderer=_chat_renderer,
        description=(
            "GuiShell on the Chat tab. SPEC-069 phase 2+3 baseline."
        ),
        threshold=PHASE_23_SSIM_THRESHOLD,
        tags=("2d", "spec-069", "phase-2-3"),
    ),
]


def register_phase23_baselines(manifest: BaselineManifest | None = None) -> None:
    """Register the phase 2+3 baselines in ``manifest`` (default-manifest
    when None). Idempotent — re-registering with the same name
    replaces the prior entry.
    """
    m = manifest if manifest is not None else default_manifest()
    for spec in PHASE_23_BASELINES:
        m.register(spec)


# Eagerly register against the default manifest so the text-API verbs
# (``visual-regression-list``, ``visual-regression-capture``,
# ``visual-regression-compare``) see them as soon as this module is
# imported. The module itself stays import-safe — no Tk roots get
# created here; renderer hooks only execute on demand.
register_phase23_baselines()
