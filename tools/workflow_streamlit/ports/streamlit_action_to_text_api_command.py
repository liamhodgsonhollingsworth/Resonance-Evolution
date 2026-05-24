"""streamlit_action_to_text_api_command — port-node implementation.

Per brief 02 commit 6 (Decision B5, SPEC-089) — the third of three
Streamlit-to-domain port-nodes. Co-spec with brief 06's text-API
command grammar (SPEC-096).

Contract:
    translate({"event": dict, "panel_state": dict}) -> {
        "command": str,            # canonical text-API command string
        "verb": str,               # the leading verb (e.g. "chat.send")
        "args": list[str],         # parsed args
        "kwargs": dict,            # flag-shaped args (--name=value)
    }

Maps Streamlit interaction events to brief 06's text-API command
grammar:

  Streamlit event                            Text-API command
  -----------------------------------------  ------------------------
  st.button("Save")        clicked           panel.<panel-name>.save
  st.button("Delete X")    clicked           panel.<panel-name>.delete X
  st.text_input(...)       changed name=v    panel.<panel-name>.set name=v
  st.chat_input("...")     submitted T       chat.send T
  st.selectbox(...)        changed v         panel.<panel-name>.select v
  st.checkbox(...)         toggled b         panel.<panel-name>.toggle b
  paste                    captured B        paste.add --mime <m> <B>
  scroll                   to y              ui.scroll_to <y>

The grammar mirrors the existing `Apeiron/tools/workflow_streamlit/
commands.py` CommandRegistry verbs so the produced commands round-trip
through the existing registry without translation.

Pure function. Idempotent.
"""
from __future__ import annotations

from typing import Any, Dict, List, Optional


def _slugify(s: Any) -> str:
    """Lowercase + strip; replace whitespace with dashes. Empty-safe."""
    if s is None:
        return ""
    txt = str(s).strip().lower()
    return "-".join(part for part in txt.split() if part)


def _panel_verb(panel: Optional[str], verb: str) -> str:
    """Format a panel.<slug>.<verb> prefix."""
    slug = _slugify(panel) or "main"
    return f"panel.{slug}.{verb}"


def _format_kwargs(kwargs: Dict[str, Any]) -> List[str]:
    """Render dict kwargs as ``key=value`` tokens for the text-API."""
    out: List[str] = []
    for k in sorted(kwargs):
        v = kwargs[k]
        if v is None:
            continue
        # Wrap in quotes when the value contains whitespace.
        v_str = str(v)
        if " " in v_str or "\t" in v_str:
            out.append(f'{k}="{v_str}"')
        else:
            out.append(f"{k}={v_str}")
    return out


def _format_command(verb: str, args: List[str], kwargs: Dict[str, Any]) -> str:
    """Assemble a one-line text-API command string.

    Token order: verb, kwargs (alphabetical), then positional args.
    This mirrors the existing CommandRegistry parser which accepts
    both forms.
    """
    parts = [verb]
    parts.extend(_format_kwargs(kwargs))
    for arg in args:
        if arg is None:
            continue
        a = str(arg)
        if " " in a or "\t" in a:
            parts.append(f'"{a}"')
        else:
            parts.append(a)
    return " ".join(parts).strip()


# --------------------------------------------------------------------------
# Per-event-type handlers
# --------------------------------------------------------------------------


def _handle_button(event: Dict[str, Any], panel_state: Dict[str, Any]) -> Dict[str, Any]:
    """st.button click → panel.<slug>.<verb> [arg]

    Convention: the button label encodes the verb (first word) +
    optional arg (remaining words). "Save" → save; "Delete X" →
    delete X. The encoding is a maintainer-friendly default; explicit
    ``action_verb`` + ``action_args`` keys on the event override.
    """
    panel = event.get("panel") or panel_state.get("panel_name")
    label = event.get("label", "")
    action_verb = event.get("action_verb")
    action_args = event.get("action_args") or []
    if not action_verb:
        # Derive from the label.
        tokens = [t for t in str(label).split() if t]
        if not tokens:
            action_verb = "click"
        else:
            action_verb = _slugify(tokens[0])
            if len(tokens) > 1:
                action_args = tokens[1:] + list(action_args)
    args = [str(a) for a in action_args]
    return {"verb": _panel_verb(panel, action_verb), "args": args, "kwargs": {}}


def _handle_text_input(event: Dict[str, Any], panel_state: Dict[str, Any]) -> Dict[str, Any]:
    """st.text_input change → panel.<slug>.set name=<value>"""
    panel = event.get("panel") or panel_state.get("panel_name")
    name = event.get("name") or event.get("widget_key") or "value"
    value = event.get("value", "")
    return {
        "verb": _panel_verb(panel, "set"),
        "args": [],
        "kwargs": {str(name): value},
    }


def _handle_chat_input(event: Dict[str, Any], panel_state: Dict[str, Any]) -> Dict[str, Any]:
    """st.chat_input submission → chat.send <text>

    The text-API command bypasses any panel-prefix because chat.send
    is a global verb in the existing command registry.
    """
    text = event.get("text", "")
    return {"verb": "chat.send", "args": [str(text)], "kwargs": {}}


def _handle_selectbox(event: Dict[str, Any], panel_state: Dict[str, Any]) -> Dict[str, Any]:
    """st.selectbox change → panel.<slug>.select <value>"""
    panel = event.get("panel") or panel_state.get("panel_name")
    value = event.get("value", "")
    return {
        "verb": _panel_verb(panel, "select"),
        "args": [str(value)],
        "kwargs": {},
    }


def _handle_checkbox(event: Dict[str, Any], panel_state: Dict[str, Any]) -> Dict[str, Any]:
    """st.checkbox toggle → panel.<slug>.toggle name=<bool>"""
    panel = event.get("panel") or panel_state.get("panel_name")
    name = event.get("name") or event.get("widget_key") or "checked"
    value = event.get("value", False)
    return {
        "verb": _panel_verb(panel, "toggle"),
        "args": [],
        "kwargs": {str(name): "true" if value else "false"},
    }


def _handle_paste(event: Dict[str, Any], panel_state: Dict[str, Any]) -> Dict[str, Any]:
    """ClipboardEvent → paste.add --mime <m> <content>

    Mirrors the JS handler emitted by `workflow_continuous_scroll_v1.py`
    in brief 02 commit 4.
    """
    content = event.get("content", "")
    mime = event.get("mime")
    kwargs: Dict[str, Any] = {}
    if mime:
        kwargs["mime"] = mime
    return {"verb": "paste.add", "args": [str(content)], "kwargs": kwargs}


def _handle_scroll(event: Dict[str, Any], panel_state: Dict[str, Any]) -> Dict[str, Any]:
    """Scroll position → ui.scroll_to <y>"""
    y = event.get("scroll_y", event.get("y", 0))
    return {"verb": "ui.scroll_to", "args": [str(y)], "kwargs": {}}


def _handle_chat_router(event: Dict[str, Any], panel_state: Dict[str, Any]) -> Dict[str, Any]:
    """Chat-router lift dispatch → chat.send-with-session <text> [--session id]

    The chat-router lift's `dispatch_action(engine, "chat_router_main",
    "send", payload={"text": ..., "session_id": ...})` maps to a
    text-API form that round-trips through the same registry verbs.
    """
    text = event.get("text", "")
    session_id = event.get("session_id")
    kwargs: Dict[str, Any] = {}
    if session_id:
        kwargs["session"] = session_id
    return {"verb": "chat.send", "args": [str(text)], "kwargs": kwargs}


_EVENT_DISPATCH = {
    "button": _handle_button,
    "text_input": _handle_text_input,
    "chat_input": _handle_chat_input,
    "selectbox": _handle_selectbox,
    "checkbox": _handle_checkbox,
    "paste": _handle_paste,
    "scroll": _handle_scroll,
    "chat_router": _handle_chat_router,
}


def translate(payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Map a Streamlit event to a text-API command string.

    Input shape:
        {"event": {"type": <event-type>, ...event-specific-fields},
         "panel_state": <dict carrying panel_name etc>?}

    Output shape:
        {"command": str, "verb": str, "args": list[str], "kwargs": dict}

    Pure + idempotent. Unknown event types route through a generic
    fallback that produces ``panel.<slug>.<event-type>`` with the
    event's ``args`` + ``kwargs`` keys (when present).
    """
    if payload is None:
        payload = {}
    if not isinstance(payload, dict):
        raise TypeError(
            f"streamlit_action_to_text_api_command.translate: payload must "
            f"be a dict; got {type(payload).__name__}"
        )
    event = payload.get("event") or {}
    if not isinstance(event, dict):
        raise TypeError(
            f"translate: payload['event'] must be a dict; got {type(event).__name__}"
        )
    panel_state = payload.get("panel_state") or {}
    if not isinstance(panel_state, dict):
        panel_state = {}

    event_type = event.get("type") or "unknown"
    handler = _EVENT_DISPATCH.get(event_type)
    if handler is None:
        # Fallback: produce a panel-prefixed verb whose name IS the
        # event type. The maintainer can intercept these on the CLI side.
        panel = event.get("panel") or panel_state.get("panel_name")
        result = {
            "verb": _panel_verb(panel, _slugify(event_type) or "event"),
            "args": list(event.get("args") or []),
            "kwargs": dict(event.get("kwargs") or {}),
        }
    else:
        result = handler(event, panel_state)

    verb = result["verb"]
    args = result["args"]
    kwargs = result["kwargs"]
    command = _format_command(verb, args, kwargs)
    return {
        "command": command,
        "verb": verb,
        "args": args,
        "kwargs": kwargs,
    }


__all__ = ["translate"]
