# Streamlit workflow surface

The HTML/browser rendering of the Apeiron workflow surface. Drives the
same engine, session manager, and inbox primitives that the terminal
shell (`tools/workflow`) and the Tk GUI (`tools/workflow_gui`) use, so
swapping between any of the three is a no-data-migration switch.

## Quick start (local)

From the Apeiron repo root, with `python` and `streamlit` installed:

    python -m tools.workflow_streamlit

The browser opens to `http://localhost:8501`. You are auto-signed-in as
`LHH` (configurable via `APEIRON_LOCAL_USER`); the workflow-management
session auto-spawns and the chat panel is wired against it.

## Add a panel

Drop a file under [`panels/`](panels/) with this contract:

```python
from ._common import MOUNT_MAIN, PanelContext, PanelManifest

def manifest() -> PanelManifest:
    return PanelManifest(
        name="my-panel",
        description="What this surface shows.",
        mount_point=MOUNT_MAIN,   # or MOUNT_SIDEBAR, MOUNT_BOTTOM, MOUNT_GATE
        order=50,
    )

def render(ctx: PanelContext) -> None:
    import streamlit as st
    st.write("hello, world.")
```

Mount points:

- `MOUNT_SIDEBAR` — left-rail panels (session status, scene picker, idea queue).
- `MOUNT_MAIN` — central pane (workflow view, full-screen panels).
- `MOUNT_BOTTOM` — under the main pane (chat).
- `MOUNT_GATE` — runs before everything else; auth panel uses this to short-circuit unauthenticated requests.

Within a mount point, panels render in `order` order (lower first).

## Web deployment

Two env vars switch the surface from "local" mode to "web" mode:

- `APEIRON_REQUIRE_LOGIN=1` — show the scrypt-backed login form rather
  than auto-signing-in. Credentials are validated against the existing
  `state/accounts.json` store (same one the Tk GUI uses).
- `APEIRON_LOCAL_USER` — override the auto-login username. Ignored
  when `APEIRON_REQUIRE_LOGIN=1`.

Deployment to Streamlit Community Cloud, Render, Fly, or any host that
runs `streamlit run` works unchanged. The state directory
(`state/workflow/`) must be on persistent storage so sessions survive
restarts; otherwise no host-specific config.

## Architecture

```
tools/workflow_streamlit/
├── app.py                  Streamlit page — discovers + mounts panels
├── runtime.py              cached Engine/SessionManager/Inbox/FileWatcher
├── registry.py             walks panels/ and surfaces (manifest, render) pairs
├── config.py               env-driven RuntimeConfig
├── style.py                CSS injection (dark theme)
├── _common_imports.py      shared re-exports
└── panels/
    ├── _common.py          PanelContext + PanelManifest
    ├── auth_panel.py       login gate (gate mount)
    ├── session_panel.py    sidebar — active session status
    ├── scene_picker_panel.py sidebar — scene selector
    ├── idea_queue_panel.py sidebar — drag-rearrangeable idea queue
    ├── workflow_panel.py   main — tasks/ideas/wishes columns
    ├── items_panel.py      main — generic items-from-cache helper
    └── chat_panel.py       bottom — inbox-backed chat with the session
```

Adding a new panel never requires editing `app.py`, `runtime.py`, or
`registry.py`. The discovery contract is the only coupling.

## Relationship to the Tk GUI and terminal shell

All three renderers read from `engine.cache[<source_id>]` for items
panels, `Inbox.list_all()` for messages, and `SessionManager` for
session state. A node-type added by any session shows up in all three
the same way. The Streamlit surface is the one designed to portably
deploy to a web host once the Resonance domains are live.
