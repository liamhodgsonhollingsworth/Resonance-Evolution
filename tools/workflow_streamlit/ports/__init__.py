"""Streamlit-to-domain port-node implementations (brief 02 commit 6).

Three port-nodes per SPEC-089 / Decision B5 of the brief 02 per-module plan:

1. ``streamlit_session_to_url_grammar`` — URL identity.
2. ``streamlit_panel_to_renderer_node`` — wrap a Streamlit panel as a
   renderer-node.
3. ``streamlit_action_to_text_api_command`` — translate Streamlit events
   to text-API commands per SPEC-096 grammar.

Each module exports a ``translate(payload) -> result`` callable that
the substrate's ``execute(port_node, input)`` dispatch (per SPEC-085)
reaches via the `python-callable` impl-kind. The corresponding
substrate-side port-spec nodes live at
``Alethea-cc/substrate/nodes/port_<name>.md``.

Per mistake #009: zero new substrate primitives — the port-spec body-
format + `kind: port` dispatcher + `_execute_port` handler all landed
in brief 01 commit 1. This commit reifies three specific ports
against that primitive, plus extends `_EXECUTE_IMPL_DISPATCH` with
the `streamlit-wrapper` impl-kind that the second port emits.
"""
from .streamlit_session_to_url_grammar import translate as translate_session_to_url
from .streamlit_panel_to_renderer_node import translate as translate_panel_to_renderer
from .streamlit_action_to_text_api_command import translate as translate_action_to_command

__all__ = [
    "translate_session_to_url",
    "translate_panel_to_renderer",
    "translate_action_to_command",
]
