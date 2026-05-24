"""Tests for the three Streamlit-to-domain port-node impls (brief 02 commit 6, SPEC-089).

Covers:
  - port 1: streamlit_session_to_url_grammar — URL formatting + parse_url
    round-trip equality + idempotency + per-content-type field handling.
  - port 2: streamlit_panel_to_renderer_node — renderer-spec body shape +
    streamlit-wrapper impl-kind + fallback when panel module is missing.
  - port 3: streamlit_action_to_text_api_command — per-event-type handling +
    grammar conformance + idempotency.
  - All three ports composing the SPEC-085 port contract (return-shape
    matches the substrate-side port-spec's output schema).

Per SPEC-081: each port is library-shape; tests exercise the LIBRARY
contract directly without spawning the substrate.
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Dict

import pytest

HERE = Path(__file__).resolve().parent
APEIRON_ROOT = HERE.parent
if str(APEIRON_ROOT) not in sys.path:
    sys.path.insert(0, str(APEIRON_ROOT))

from tools.workflow_streamlit.ports.streamlit_session_to_url_grammar import (
    translate as translate_session,
    parse_url,
)
from tools.workflow_streamlit.ports.streamlit_panel_to_renderer_node import (
    translate as translate_panel,
)
from tools.workflow_streamlit.ports.streamlit_action_to_text_api_command import (
    translate as translate_action,
)


# ---------------------------------------------------------------------------
# Port 1 — streamlit_session_to_url_grammar
# ---------------------------------------------------------------------------


class TestPort1SessionToUrl:
    def test_empty_input_returns_default(self):
        r = translate_session({})
        assert r["renderer_id"] == "workflow_continuous_scroll_v1"
        assert r["content_node_ids"] == []
        assert r["query"] == {}
        assert r["url"] == "#workflow_continuous_scroll_v1"

    def test_panel_mapping_chat(self):
        r = translate_session({"session_state": {}, "current_panel": "chat"})
        assert r["renderer_id"] == "chat_router_v1"
        assert r["url"].startswith("#chat_router_v1")

    def test_unknown_panel_passes_through(self):
        r = translate_session({"session_state": {}, "current_panel": "my-custom-panel"})
        assert r["renderer_id"] == "my-custom-panel"

    def test_anchor_in_query(self):
        r = translate_session({
            "session_state": {"anchor": "sha256:abc"},
            "current_panel": "workflow-continuous-scroll",
        })
        assert r["query"].get("anchor") == "sha256:abc"
        assert "anchor=sha256%3Aabc" in r["url"]

    def test_window_in_query(self):
        r = translate_session({
            "session_state": {"window": "10,5,5"},
            "current_panel": "workflow-continuous-scroll",
        })
        assert r["query"].get("window") == "10,5,5"

    def test_internal_session_keys_dropped(self):
        r = translate_session({
            "session_state": {
                "_FormSubmitterDirect": "form-noise",
                "_streamlit_pages_": "page-noise",
                "anchor": "sha256:visible",
            },
            "current_panel": "workflow-continuous-scroll",
        })
        # Internal keys should not appear in the URL or query.
        assert "_FormSubmitterDirect" not in r["url"]
        assert "_FormSubmitterDirect" not in r["query"]
        assert r["query"].get("anchor") == "sha256:visible"

    def test_content_node_ids_extracted_from_strings(self):
        r = translate_session({
            "session_state": {
                "current_anchor": "sha256:aaa",
                "another_ref": "sha256:bbb",
            },
            "current_panel": "workflow-continuous-scroll",
        })
        assert "sha256:aaa" in r["content_node_ids"]
        assert "sha256:bbb" in r["content_node_ids"]

    def test_content_node_ids_extracted_from_positions_list(self):
        r = translate_session({
            "session_state": {
                "positions": [
                    {"node_id": "sha256:p1", "appended_at": "..."},
                    {"node_id": "sha256:p2", "appended_at": "..."},
                ],
            },
            "current_panel": "workflow-continuous-scroll",
        })
        assert "sha256:p1" in r["content_node_ids"]
        assert "sha256:p2" in r["content_node_ids"]

    def test_query_prefix_passthrough(self):
        r = translate_session({
            "session_state": {"query_extra_key": "extraval"},
            "current_panel": "workflow-continuous-scroll",
        })
        assert r["query"].get("extra_key") == "extraval"

    def test_idempotency(self):
        ss = {"anchor": "sha256:abc", "window": "20,10,10"}
        r1 = translate_session({"session_state": ss, "current_panel": "workflow-continuous-scroll"})
        r2 = translate_session({"session_state": ss, "current_panel": "workflow-continuous-scroll"})
        assert r1 == r2

    def test_url_round_trip_matches_triple(self):
        session = {"anchor": "sha256:xyz", "window": "5,2,2", "current_anchor": "sha256:xyz"}
        r = translate_session({
            "session_state": session,
            "current_panel": "workflow-continuous-scroll",
        })
        parsed = parse_url(r["url"])
        assert parsed["renderer_id"] == r["renderer_id"]
        assert parsed["query"] == r["query"]
        # content_node_ids preserves the first; remaining via the "also" query.
        assert set(parsed["content_node_ids"]) >= set(r["content_node_ids"])

    def test_invalid_payload_raises_typeerror(self):
        with pytest.raises(TypeError):
            translate_session("not a dict")  # type: ignore


# ---------------------------------------------------------------------------
# Port 2 — streamlit_panel_to_renderer_node
# ---------------------------------------------------------------------------


class TestPort2PanelToRenderer:
    def test_returns_renderer_spec_shape(self):
        r = translate_panel({"panel_module": "chat_panel"})
        assert r["kind"] == "renderer"
        assert r["body-format"] == "renderer-spec"
        assert "body" in r
        assert "name" in r

    def test_body_implementation_is_streamlit_wrapper(self):
        r = translate_panel({"panel_module": "chat_panel"})
        impl = r["body"]["implementation"]
        assert impl["kind"] == "streamlit-wrapper"
        assert "path" in impl
        assert impl["path"].startswith("Apeiron/tools/workflow_streamlit/panels/")
        assert impl["path"].endswith("chat_panel.py")

    def test_body_has_input_and_output_schemas(self):
        r = translate_panel({"panel_module": "chat_panel"})
        assert "input" in r["body"] and "schema" in r["body"]["input"]
        assert "output" in r["body"] and "schema" in r["body"]["output"]
        assert r["body"]["output"]["schema"]["format"] == "html"

    def test_unknown_panel_falls_back_gracefully(self):
        r = translate_panel({"panel_module": "this-panel-does-not-exist"})
        # The translate still produces a renderer-spec shape; the
        # manifest data has an "error" key surfaced via _origin.
        assert r["kind"] == "renderer"
        assert r["_origin"]["manifest_status"] == "fallback"

    def test_idempotency(self):
        r1 = translate_panel({"panel_module": "chat_panel"})
        r2 = translate_panel({"panel_module": "chat_panel"})
        assert r1["name"] == r2["name"]
        assert r1["body"]["implementation"] == r2["body"]["implementation"]

    def test_invalid_payload_raises(self):
        with pytest.raises(TypeError):
            translate_panel("not a dict")  # type: ignore
        with pytest.raises(ValueError):
            translate_panel({})

    def test_path_prefix_override(self):
        r = translate_panel({
            "panel_module": "chat_panel",
            "path_prefix": "Custom/path/to/panels/",
        })
        assert r["body"]["implementation"]["path"] == "Custom/path/to/panels/chat_panel.py"

    def test_origin_tracks_source_panel(self):
        r = translate_panel({"panel_module": "chat_panel"})
        assert r["_origin"]["port"] == "streamlit_panel_to_renderer_node"
        assert r["_origin"]["source_panel_module"] == "chat_panel"


# ---------------------------------------------------------------------------
# Port 3 — streamlit_action_to_text_api_command
# ---------------------------------------------------------------------------


class TestPort3ActionToCommand:
    def test_button_click_basic(self):
        r = translate_action({
            "event": {"type": "button", "panel": "workflow", "label": "Save"},
            "panel_state": {},
        })
        assert r["verb"] == "panel.workflow.save"
        assert r["command"] == "panel.workflow.save"

    def test_button_label_with_arg(self):
        r = translate_action({
            "event": {"type": "button", "panel": "workflow", "label": "Delete X"},
            "panel_state": {},
        })
        assert r["verb"] == "panel.workflow.delete"
        assert "X" in r["args"]

    def test_chat_input_emits_chat_send(self):
        r = translate_action({
            "event": {"type": "chat_input", "text": "hello world"},
            "panel_state": {},
        })
        assert r["verb"] == "chat.send"
        assert "hello world" in r["command"]

    def test_text_input_change_to_set(self):
        r = translate_action({
            "event": {"type": "text_input", "name": "max_messages", "value": "40"},
            "panel_state": {"panel_name": "chat"},
        })
        assert r["verb"] == "panel.chat.set"
        assert r["kwargs"].get("max_messages") == "40"
        assert "max_messages=40" in r["command"]

    def test_selectbox_emits_select(self):
        r = translate_action({
            "event": {"type": "selectbox", "value": "option-1"},
            "panel_state": {"panel_name": "scene-picker"},
        })
        assert r["verb"] == "panel.scene-picker.select"
        assert "option-1" in r["args"]

    def test_checkbox_emits_toggle(self):
        r = translate_action({
            "event": {"type": "checkbox", "name": "enabled", "value": True},
            "panel_state": {"panel_name": "auth"},
        })
        assert r["verb"] == "panel.auth.toggle"
        assert r["kwargs"].get("enabled") == "true"

    def test_paste_emits_paste_add(self):
        r = translate_action({
            "event": {"type": "paste", "content": "abc123", "mime": "text/plain"},
            "panel_state": {},
        })
        assert r["verb"] == "paste.add"
        assert r["kwargs"].get("mime") == "text/plain"
        assert "abc123" in r["command"]

    def test_scroll_emits_ui_scroll_to(self):
        r = translate_action({
            "event": {"type": "scroll", "scroll_y": 1234},
            "panel_state": {},
        })
        assert r["verb"] == "ui.scroll_to"
        assert "1234" in r["args"]

    def test_chat_router_with_session(self):
        r = translate_action({
            "event": {"type": "chat_router", "text": "hi", "session_id": "abc-def"},
            "panel_state": {},
        })
        assert r["verb"] == "chat.send"
        assert r["kwargs"].get("session") == "abc-def"

    def test_unknown_event_type_falls_back(self):
        r = translate_action({
            "event": {"type": "drag_drop", "panel": "workflow"},
            "panel_state": {},
        })
        # Fallback: panel.<slug>.drag-drop
        assert r["verb"].startswith("panel.workflow.")
        assert "drag" in r["verb"] or "drop" in r["verb"]

    def test_idempotency(self):
        ev = {"event": {"type": "button", "label": "Save", "panel": "x"}, "panel_state": {}}
        r1 = translate_action(ev)
        r2 = translate_action(ev)
        assert r1 == r2

    def test_invalid_payload_raises(self):
        with pytest.raises(TypeError):
            translate_action("not a dict")  # type: ignore
        with pytest.raises(TypeError):
            translate_action({"event": "not a dict"})

    def test_command_format_handles_whitespace_in_args(self):
        r = translate_action({
            "event": {"type": "chat_input", "text": "two words"},
            "panel_state": {},
        })
        # Whitespace-containing positional arg should be quoted.
        assert '"two words"' in r["command"] or "two words" in r["command"]


# ---------------------------------------------------------------------------
# Composition — all three ports together against the SPEC-085 port contract
# ---------------------------------------------------------------------------


class TestPortContractCompliance:
    def test_all_three_ports_are_pure_functions(self):
        """No side effects: calling each port twice with the same input
        must produce the same output (no state-mutation)."""
        ss = {"session_state": {"anchor": "sha256:a"}, "current_panel": "workflow-continuous-scroll"}
        assert translate_session(ss) == translate_session(ss)

        panel_in = {"panel_module": "chat_panel"}
        r1 = translate_panel(panel_in)
        r2 = translate_panel(panel_in)
        # Body content matches.
        assert r1["body"]["implementation"] == r2["body"]["implementation"]

        action_in = {"event": {"type": "button", "label": "Save"}, "panel_state": {}}
        assert translate_action(action_in) == translate_action(action_in)

    def test_port_1_output_schema_shape(self):
        r = translate_session({"session_state": {}, "current_panel": "x"})
        for key in ("renderer_id", "content_node_ids", "query", "url"):
            assert key in r

    def test_port_2_output_schema_shape(self):
        r = translate_panel({"panel_module": "chat_panel"})
        for key in ("name", "kind", "body-format", "body"):
            assert key in r

    def test_port_3_output_schema_shape(self):
        r = translate_action({"event": {"type": "button", "label": "Go"}, "panel_state": {}})
        for key in ("command", "verb", "args", "kwargs"):
            assert key in r
