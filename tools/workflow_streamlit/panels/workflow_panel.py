"""Three-column workflow view — Tasks, Ideas, Wishes side by side.

Composes ``items_panel.render_items_list`` against the FileSource node
ids that the WorkflowView scene already publishes into ``engine.cache``.
The source ids match the scene at ``scenes/workflow_view.json`` and are
the same ids the Tk GUI's tab list resolves; we deliberately reuse them
so all three surfaces (Tk, Streamlit, 3D ListRenderer) read the same
cache entries.

If the scene isn't loaded (the engine is empty), each column degrades
to its empty hint rather than crashing. The driver still renders.
"""

from __future__ import annotations

import streamlit as st

from tools.workflow_streamlit.panels import items_panel
from tools.workflow_streamlit.panels._common import MOUNT_MAIN, PanelContext, PanelManifest


# Source ids match the FileSource nodes in scenes/workflow_view.json.
# Source-of-truth: ``scenes/workflow_view.json`` + the WorkflowView
# composite at ``node_types/workflow_view.py``. Keeping them inline here
# avoids importing scene JSON at panel-discovery time.
COLUMNS = (
    ("Tasks", "tasks_source", "no tasks (tasks.md)"),
    ("Ideas", "ideas_source", "no ideas (Alethea ideas_queue.md)"),
    ("Wishes", "wishes_source", "no wishes (wishlist.md)"),
)


def manifest() -> PanelManifest:
    return PanelManifest(
        name="workflow-view",
        description="Three-column Tasks / Ideas / Wishes panel from the engine cache.",
        mount_point=MOUNT_MAIN,
        order=10,
    )


def render(ctx: PanelContext) -> None:
    st.markdown("## Workflow")
    cols = st.columns(len(COLUMNS), gap="medium")
    for col, (title, source_id, empty) in zip(cols, COLUMNS):
        with col:
            items_panel.render_items_list(
                ctx,
                title=title,
                source_id=source_id,
                empty_hint=empty,
            )
