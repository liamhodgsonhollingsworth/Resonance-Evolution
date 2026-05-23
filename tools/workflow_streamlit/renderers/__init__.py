"""Workflow-surface renderers.

Per brief 02 commit 2 (per-module plan
`Alethea/notes/website_planning_arc/per_module_plans/02_workflow_surface.md`).

Each renderer module corresponds to a substrate `kind: renderer` node
published under `Alethea-cc/substrate/nodes/`. The Streamlit-side panel
modules at `panels/<name>.py` import the renderer's `render(input)`
function directly; the literal-domain bootstrap (commit 7) reaches the
same `render` callable via the substrate's `kind: renderer` dispatch.

Bootstrap roster (brief 02 commit 2):
  - workflow_continuous_scroll_v1 — continuous-scroll workflow surface;
    sliding-window 50 + 20 + 20 per Decision B1.
  - sliding_window — pure-function band-selection helper consumed by the
    continuous-scroll renderer (extracted as a separate module per the
    per-module plan so other renderers / test harnesses can reuse it
    without importing the HTML-emitting layer).
"""
