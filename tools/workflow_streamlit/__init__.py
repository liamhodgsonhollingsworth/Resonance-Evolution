"""Streamlit/HTML rendering of the Apeiron workflow surface.

A third renderer alongside the Tk GUI (``tools.workflow_gui``) and the
terminal REPL (``tools.workflow``). All three drive the same underlying
``Engine`` + ``SessionManager`` + ``Inbox`` + ``auth`` primitives — the
visualizer-as-toggle commitment from SPEC-061. The Streamlit rendering
is the one designed to deploy unchanged to a web host once domains are
wired up; see ``config.py::deployment_mode`` for the env-driven switch.

Composition is panel-by-panel: every Streamlit-side surface lives in
``panels/`` as a single Python file with a ``manifest()`` + ``render()``
pair (the same contract Apeiron's node-types use under ``node_types/``).
The driver in ``app.py`` discovers panels at startup, the registry
mounts them by their declared ``mount_point``, and adding a new panel is
a single-file drop with no edits to the driver. New panel files are
picked up on the next Streamlit autoreload — no server restart required.
"""
