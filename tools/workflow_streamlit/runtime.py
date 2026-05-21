"""Cached singletons — Engine, SessionManager, Inbox, FileWatcher.

Streamlit reruns the script on every interaction, so anything that is
expensive to construct (or that must survive across reruns to keep its
state) lives behind ``@st.cache_resource``. The cached objects share the
exact lifecycle the Tk GUI and terminal REPL already use — same Engine
constructor, same SessionManager, same Inbox — so all three surfaces
read and write through the same underlying state with no surprise.

The default workflow-management session is auto-spawned on first
launch (SPEC-002 / SPEC-003) the same way ``tools.workflow.shell`` does,
keyed by the same persistent marker file at
``state/workflow/default_workflow_mgmt.txt``. Re-running the Streamlit
process picks up the existing session by id rather than respawning.
"""

from __future__ import annotations

import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

import streamlit as st

from .config import RuntimeConfig


@dataclass
class Runtime:
    """Bundle of the long-lived objects every panel needs."""
    engine: Any
    session_manager: Any
    inbox: Any
    file_watcher: Any
    config: RuntimeConfig
    default_session_id: Optional[str]


@st.cache_resource(show_spinner="booting Apeiron engine…")
def boot_runtime(config_kwargs: tuple) -> Runtime:
    """Construct or fetch the cached runtime.

    ``config_kwargs`` is a tuple of (key, value) pairs so Streamlit's
    cache key is hashable. The actual values come from
    ``config.load_config()`` upstream — but the cache key is the
    pickled form, so reusing the same config produces the same
    cached runtime.
    """
    from .config import load_config
    cfg = load_config(Path(dict(config_kwargs)["apeiron_root"]))

    from engine.core import Engine
    from engine.file_watcher import FileWatcher

    engine = Engine(root_dir=cfg.apeiron_root)
    engine.discover()
    scene_path = cfg.apeiron_root / "scenes" / cfg.default_scene
    if scene_path.exists():
        try:
            engine.load_scene(scene_path)
            engine.precompute()
        except Exception:
            pass

    file_watcher = FileWatcher(engine=engine)
    file_watcher.start()

    from tools.workflow.session_manager import SessionManager
    from tools.workflow.inbox import Inbox

    state_dir = cfg.state_dir
    state_dir.mkdir(parents=True, exist_ok=True)
    sm = SessionManager(state_dir=state_dir)
    inbox = Inbox(state_dir=state_dir)

    default_session_id = _ensure_default_session(sm, cfg)

    return Runtime(
        engine=engine,
        session_manager=sm,
        inbox=inbox,
        file_watcher=file_watcher,
        config=cfg,
        default_session_id=default_session_id,
    )


def _ensure_default_session(sm: Any, cfg: RuntimeConfig) -> Optional[str]:
    """Spawn or resume the always-on workflow-management session.

    Mirrors ``tools.workflow.shell.Shell.ensure_default_workflow_mgmt_session``
    but never blocks the Streamlit page on spawn failure (a missing
    ``claude`` CLI on PATH just leaves ``default_session_id`` as None and
    the chat panel surfaces the situation rather than crashing).
    """
    marker = cfg.state_dir / "default_workflow_mgmt.txt"
    existing_id: Optional[str] = None
    if marker.exists():
        try:
            existing_id = marker.read_text(encoding="utf-8").strip() or None
        except Exception:
            existing_id = None
    if existing_id:
        rec = sm.get(existing_id)
        if rec is not None and rec.status != "archived":
            return existing_id
    try:
        rec = sm.spawn(
            session_type="workflow-management",
            display_name="workflow-mgmt-default",
            cwd=cfg.apeiron_root,
            seed_message=_default_seed_message(cfg),
        )
    except Exception:
        return None
    try:
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(rec.id, encoding="utf-8")
    except Exception:
        pass
    return rec.id


def _default_seed_message(cfg: RuntimeConfig) -> str:
    """Seed prompt for the workflow-management session.

    Tells the session to post user-visible messages to the inbox (with
    ``to: maintainer``) so the Streamlit chat panel can render them
    without subscribing to stream-json output. The user picked
    "inbox files" as the chat-message source — this seed enforces the
    convention on the session side.
    """
    return (
        "You are the workflow-management session for Apeiron's Streamlit "
        "workflow surface, running from the Apeiron repo at "
        f"{cfg.apeiron_root}.\n\n"
        "USER-VISIBLE MESSAGE PROTOCOL\n"
        "The maintainer only sees messages you explicitly post to the "
        "inbox (file `Alethea-cc/nodes/inbox_msg_*.md` with frontmatter "
        "`to: maintainer`). CLI stdout is NOT shown. Use the "
        "`inbox_post` MCP tool, or write the file directly, whenever "
        "you want the maintainer to see something. Keep these short — "
        "one summary line + a body if needed.\n\n"
        "BACKGROUND\n"
        "The Streamlit surface is the default GUI for Apeiron locally "
        "and will be the website surface once domains land. The same "
        "engine + session manager + inbox primitives back both. New "
        "panels drop into `tools/workflow_streamlit/panels/<name>.py` "
        "with a `manifest()` + `render(ctx)` pair; Streamlit's "
        "autoreload picks them up.\n\n"
        "ON FIRST MESSAGE\n"
        "Post one inbox message to `maintainer` with summary "
        "`workflow-mgmt-default ready` confirming you read this seed. "
        "Then wait for the next instruction."
    )


def get_runtime(cfg: RuntimeConfig) -> Runtime:
    """Idiomatic accessor — collapses the cache_resource invocation."""
    config_kwargs = (("apeiron_root", str(cfg.apeiron_root)),)
    return boot_runtime(config_kwargs)
