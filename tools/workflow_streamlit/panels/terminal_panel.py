"""Bottom-mounted, togglable terminal — the GUI↔CLI 1:1 surface.

Every GUI action in any other panel is also a textual command. When a
button is clicked, the panel calls ``CommandRegistry.run_gui`` which
dispatches the handler AND appends the shell-quoted form to the log
this panel renders. The maintainer sees the equivalent CLI command for
each click. Conversely, typing a command into this panel runs the same
handler that the button would.

External callers (the maintainer's other coding sessions; the
``tools.workflow_streamlit.cli`` script) write commands into the
bridge queue file. ``cli_bridge.drain`` is invoked at the start of
each render and dispatches anything sitting in the queue with
``source="cli"`` — those appear in the log too. The result is one
unified log of every interaction with the surface, regardless of
which interface produced it.

The terminal is toggled via a checkbox in its header; the visibility
flag lives in ``st.session_state["terminal_visible"]`` and persists
across reruns.
"""

from __future__ import annotations

from html import escape

import streamlit as st

from tools.workflow_streamlit.command_registry import format_log_entry
from tools.workflow_streamlit.panels._common import MOUNT_BOTTOM, PanelContext, PanelManifest


# How many recent log entries to render. The registry caps internally at 500.
DISPLAY_LIMIT = 80


def manifest() -> PanelManifest:
    return PanelManifest(
        name="terminal",
        description="Togglable CLI terminal — every GUI action shows its CLI equivalent.",
        mount_point=MOUNT_BOTTOM,
        order=20,
    )


def render(ctx: PanelContext) -> None:
    registry = ctx.scratch.get("command_registry")
    if registry is None:
        return

    # Toggle in the header. Default-visible so the maintainer sees the
    # CLI log immediately on first open.
    if "terminal_visible" not in st.session_state:
        st.session_state["terminal_visible"] = True
    visible = st.session_state["terminal_visible"]

    cctx = _command_context_from_panel(ctx)
    header_cols = st.columns([0.7, 0.15, 0.15])
    with header_cols[0]:
        st.markdown("## Terminal")
    with header_cols[1]:
        label = "hide" if visible else "show"
        if st.button(label, key="terminal-toggle"):
            registry.run_gui("ui.terminal.toggle", cctx)
            st.rerun()
    with header_cols[2]:
        if visible and st.button("clear", key="terminal-clear-btn"):
            registry.run_gui("clear", cctx)
            st.rerun()

    if not visible:
        st.caption("(terminal hidden — click 'show' to reopen)")
        return

    # Log first (above the input), so newest output is right above the box.
    entries = registry.log(limit=DISPLAY_LIMIT)
    if not entries:
        st.markdown(
            '<div class="empty-hint">no commands yet — try `help`</div>',
            unsafe_allow_html=True,
        )
    else:
        log_html = "<div class='terminal-log'>"
        for entry in entries:
            log_html += _format_entry_html(entry)
        log_html += "</div>"
        st.markdown(log_html, unsafe_allow_html=True)

    # The input box. ``chat_input``-style key so Enter submits.
    text = st.chat_input("type a command (try `help`)…", key="terminal-input")
    if text:
        cctx = _command_context_from_panel(ctx)
        registry.run(text, cctx, source="terminal")
        st.rerun()


def _format_entry_html(entry) -> str:
    when = escape(format_log_entry(entry).splitlines()[0].split(" ", 1)[0])
    src_label = entry.source
    src_class = {
        "gui": "term-src-gui",
        "terminal": "term-src-terminal",
        "cli": "term-src-cli",
        "system": "term-src-system",
    }.get(src_label, "term-src-system")
    cmd = escape(entry.command)
    body = (
        f'<div class="term-row">'
        f'  <span class="term-when">{when}</span>'
        f'  <span class="term-src {src_class}">[{escape(src_label)}]</span>'
        f'  <span class="term-cmd">$ {cmd}</span>'
        f"</div>"
    )
    if entry.result is not None and entry.result.message:
        marker_cls = "term-ok" if entry.result.ok else "term-err"
        marker = "OK" if entry.result.ok else "ERR"
        msg = escape(entry.result.message)
        body += (
            f'<div class="term-output {marker_cls}">'
            f'<span class="term-marker">[{marker}]</span> <pre>{msg}</pre>'
            f'</div>'
        )
    elif entry.result is not None and not entry.result.ok:
        body += '<div class="term-output term-err"><span class="term-marker">[ERR]</span></div>'
    return body


def _command_context_from_panel(ctx: PanelContext):
    from tools.workflow_streamlit.command_registry import CommandContext
    return CommandContext(
        engine=ctx.engine,
        session_manager=ctx.session_manager,
        inbox=ctx.inbox,
        file_watcher=ctx.file_watcher,
        config=ctx.config,
        apeiron_root=ctx.apeiron_root,
        active_session_id=ctx.active_session_id,
        user=ctx.user,
        scratch=ctx.scratch,
    )
