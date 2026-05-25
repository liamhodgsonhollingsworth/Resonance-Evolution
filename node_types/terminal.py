"""TerminalNode — CLI-as-substrate-primitive (SPEC-303).

The terminal substrate primitive landed via the website-MVP misframing
recovery arc (2026-05-23 / 2026-05-24). Maintainer's exact closing-turn
verbatim:

  *"the terminal being a specific node that can be linked to a text box
  node such that I can have rectangle -> text + scroll bar -> terminal
  and the text in the box is then determined full by the logic of a
  CLI."*

A TerminalNode is a SUBSTRATE-level CLI hub. It does NOT emit HTML. It
does NOT replace the existing dispatch infrastructure (`dispatch_web_
action`, `terminal_bridge.py`, `exec_shell`, `exec_python`); it COMPOSES
against them. The functional contract per the arc handoff Section 4:

  - **Inputs (manifest):** ``cli_kind`` (enum dispatch_web_action /
    shell / python_callable), ``cli_endpoint`` (string — the renderer-
    id, shell-command-template, or python-callable path), ``cli_args_
    schema`` (dict — argument shape for the chosen kind), ``cli_natural
    _language`` (bool — whether typed input first goes through a NL
    router before reaching the dispatch verb), ``input_node``,
    ``output_node``, ``history_node`` (strings — text-box-node IDs the
    terminal LINKS to via `binding`), ``visibility`` (enum hidden /
    compact / expanded — surface-state hint the renderer reads),
    ``polling_interval_ms`` (int — how often a host should poll for
    output updates), ``layer`` (int, SPEC-094), ``displayed_by``
    (string).
  - **Outputs:** ``color``, ``depth`` — empty channels (the terminal
    has no visual emit of its own; rendering happens via the linked
    text-box nodes, which the maintainer composes against in the GUI
    builder).
  - **Verbs (handle_action):**
    - ``submit(text)`` — accept a typed command; route through the
      configured `cli_kind` path; record the trace; emit the
      ``last_submit`` delta with the dispatch result.
    - ``get_state`` — read back the current visibility + last
      input/output/history snapshot.
    - ``set_visibility(visibility)`` — cycle visibility (hidden /
      compact / expanded); used by toggle-button compositions.

The three `cli_kind` paths:

  - ``dispatch_web_action`` — call the Resonance-Website
    `tools/action_dispatch.py:dispatch_web_action(renderer_id, action,
    item_id, payload)` (SPEC-097). The terminal's `cli_endpoint` is the
    renderer-id; the typed command's first token is the action-name.
    When `cli_natural_language: True`, typed input first goes through
    the NL router (currently inside Resonance-Website's
    `submit_terminal_command`; the migration to wire that logic THROUGH
    the terminal node is deferred to the chat + bottom-terminal
    compositions per arc handoff Section 4.6 — this primitive ships
    with the SHAPE to host that logic, not the logic itself).
  - ``shell`` — call the alethea MCP server's ``exec_shell`` primitive.
    The `cli_endpoint` is a shell-command template; typed input
    substitutes via `{{input}}` or appends.
  - ``python_callable`` — call the alethea MCP server's ``exec_python``
    primitive. The `cli_endpoint` is a Python expression / statement
    template; typed input substitutes via `{{input}}`.

All three paths append to the SAME action-log (Resonance-Website's
`tools/action_log.py`) so the SPEC-099 parity probe sees every
dispatch regardless of CLI kind. The dispatch itself happens through a
host-provided callable (see :func:`set_dispatch_handler`); the
substrate primitive does NOT import the host's MCP server / HTTP
endpoints. This keeps the primitive testable in isolation (pure
unit-of-work) while letting the host wire real I/O at composition
time.

Composition pattern (maintainer's exact stack):

  ``rectangle → text + scroll bar → terminal``

Read left-to-right as containment + composition: BoxNode at the
outer layer; TextBoxNode + ScrollBarNode composed inside; a
TerminalNode LINKED via ``binding.input_node`` / ``binding.output_
node`` / ``binding.history_node``. The text in the linked text-box
nodes is **determined fully by the CLI logic** the terminal node
hosts — the text-box is a display surface; the terminal's CLI is
the source of truth.

Composes with:

- SPEC-097 (`dispatch_web_action` as single source of truth) — the
  ``dispatch_web_action`` cli_kind routes through this endpoint
  verbatim.
- SPEC-099 (text-vs-visual parity probe) — every dispatch the
  terminal makes is text-API-equivalent because the underlying
  `dispatch_web_action` / `exec_shell` / `exec_python` are all
  text-API callable.
- SPEC-098 (terminal-bridge HTTP) — `dispatch_web_action` cli_kind
  composes against the bridge's POST /terminal/dispatch endpoint
  when the host wires the dispatch handler accordingly.
- SPEC-152 (kind: routine) — a routine action with
  ``action.kind: python_callable`` pointed at a TerminalNode's
  submit verb dispatches the same way a human-typed command does.
- The GUI-builder primitive set (BoxNode, TextBoxNode, ScrollBarNode,
  ButtonNode, BarNode) — terminal is the substrate node-type that
  unblocks the chat + bottom-terminal compositions per the migration
  map in the arc handoff Section 3.
"""

from __future__ import annotations

from typing import Any, Callable, Dict, List, Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


# Three CLI kinds. The enum is the canonical taxonomy for the
# terminal's dispatch routes. New kinds extend this tuple ADDITIVELY +
# add a corresponding branch in `_dispatch_via_handler`. Per the arc
# handoff Section 4.4: all three append to the same action-log and
# respect the same parity probe; the difference is purely the dispatch
# endpoint.
CLI_KINDS = ("dispatch_web_action", "shell", "python_callable")

# Three visibility states. Match the existing bottom-terminal renderer's
# three-state toggle so existing compositions that polled the bespoke
# renderer's state can read the terminal-node's `visibility` field
# 1:1 during migration.
VISIBILITIES = ("hidden", "compact", "expanded")

DEFAULT_POLLING_INTERVAL_MS = 500
DEFAULT_LAYER = 0


def manifest() -> Manifest:
    return Manifest(
        name="TerminalNode",
        version="1.0",
        renderer_id="raster",
        inputs={
            # CLI configuration — what kind of dispatch route, which
            # endpoint, what argument shape, whether to NL-route input.
            "cli_kind": "string",
            "cli_endpoint": "string",
            "cli_args_schema": "dict",
            "cli_natural_language": "bool",
            # Binding to text-box nodes (maintainer's "linked-to" spec).
            "input_node": "string",
            "output_node": "string",
            "history_node": "string",
            # Surface-state hints the renderer reads.
            "visibility": "string",
            "polling_interval_ms": "int",
            # Z-order + visual-variant override (SPEC-094 + SPEC-090).
            "layer": "int",
            "displayed_by": "string",
        },
        outputs={"color": "rgb_image", "depth": "depth_image"},
        description=(
            "Terminal substrate primitive (SPEC-303). Hosts CLI logic; "
            "links to TextBoxNode for input/output/history per "
            "maintainer's verbatim spec. Three cli_kind paths: "
            "dispatch_web_action / shell / python_callable. No visual "
            "emit of its own — rendering happens via linked text-boxes."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    """Validate + normalise the params dict.

    Every field is optional in the manifest sense; defaults match the
    arc handoff Section 4.1 contract. The enum fields (`cli_kind`,
    `visibility`) fall back to sensible defaults rather than raising
    so a partial build doesn't crash the engine — surfaced via
    `describe()` so the LLM-driver notices missing wiring.

    `cli_args_schema` is stored as a plain dict for round-trip through
    the standard JSON serializer.
    """
    cli_kind = str(params.get("cli_kind") or "dispatch_web_action")
    if cli_kind not in CLI_KINDS:
        cli_kind = "dispatch_web_action"

    visibility = str(params.get("visibility") or "compact")
    if visibility not in VISIBILITIES:
        visibility = "compact"

    args_schema = params.get("cli_args_schema", {}) or {}
    if not isinstance(args_schema, dict):
        args_schema = {}

    return {
        "cli_kind": cli_kind,
        "cli_endpoint": str(params.get("cli_endpoint") or ""),
        "cli_args_schema": dict(args_schema),
        "cli_natural_language": bool(params.get("cli_natural_language") or False),
        "input_node": str(params.get("input_node") or ""),
        "output_node": str(params.get("output_node") or ""),
        "history_node": str(params.get("history_node") or ""),
        "visibility": visibility,
        "polling_interval_ms": int(
            params.get("polling_interval_ms") or DEFAULT_POLLING_INTERVAL_MS
        ),
        "layer": int(params.get("layer") or DEFAULT_LAYER),
        "displayed_by": str(params.get("displayed_by") or ""),
        # Per-instance state — last input + last output + history list.
        # Populated by handle_action; consulted by describe().
        "last_input": "",
        "last_output": "",
        "history": [],
    }


def select_children(state, view: View, engine, node) -> List[str]:
    """Terminals have no rendered children — they're a dispatch hub.
    The text-box nodes the terminal LINKS to (via binding.input_node /
    binding.output_node / binding.history_node) are SIBLING nodes; the
    link is via field-reference, not parent-child containment."""
    return []


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """No visual output — the GUI shell renders via the linked text-
    boxes. A TerminalNode wired into a scene as a render target (legal
    but unusual) contributes nothing instead of crashing. The
    text-API observation surface is :func:`describe`."""
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }


def describe(state, ctx: EmitContext) -> str:
    """One-line summary for the text-API.

    Surfaces the cli_kind + endpoint + the three bindings + visibility
    + the latest input/output snapshot. This is the LLM-driver's
    introspection surface — everything the driver needs to assess
    whether the terminal is wired correctly appears here.
    """
    cli_kind = state.get("cli_kind", "dispatch_web_action")
    endpoint = state.get("cli_endpoint") or "(unset)"
    nl = "NL" if state.get("cli_natural_language") else "verb"
    input_node = state.get("input_node") or "(unbound)"
    output_node = state.get("output_node") or "(unbound)"
    history_node = state.get("history_node") or "(unbound)"
    visibility = state.get("visibility", "compact")
    last_input = (state.get("last_input") or "")[:30].replace("\n", " ")
    if len(state.get("last_input") or "") > 30:
        last_input += "…"
    history_len = len(state.get("history") or [])
    return (
        f"TerminalNode id={ctx.node.id} "
        f"cli={cli_kind}({nl})→{endpoint} "
        f"in={input_node} out={output_node} hist={history_node} "
        f"vis={visibility} last_input={last_input!r} "
        f"history_len={history_len}"
    )


# ---------------------------------------------------------------------------
# Dispatch handler registry — set by the HOST (Resonance-Website,
# Streamlit panel, test harness, etc.). The substrate primitive does
# NOT import the host's MCP server / HTTP endpoints; the host wires
# the handler at composition time. This keeps the primitive testable
# in isolation and makes the cli_kind paths host-agnostic.
# ---------------------------------------------------------------------------


# Module-level handler slot. ``set_dispatch_handler`` writes; ``submit``
# reads. The handler signature mirrors action_dispatch.dispatch_web_action:
# ``handler(cli_kind, endpoint, payload) -> (success: bool, message: str,
# output: str)``. ``cli_kind`` is one of CLI_KINDS; ``endpoint`` is the
# state's cli_endpoint; ``payload`` is the per-dispatch dict (parsed
# from the typed input + any args_schema).
#
# When no handler is registered, ``submit`` records a NO-OP trace
# (success=False, output="no dispatch handler registered") so tests can
# verify the substrate-level state-transitions without booting the
# host.
_DISPATCH_HANDLER: Optional[Callable[[str, str, Dict[str, Any]], tuple[bool, str, str]]] = None


def set_dispatch_handler(
    handler: Optional[Callable[[str, str, Dict[str, Any]], tuple[bool, str, str]]],
) -> None:
    """Register the host's dispatch handler.

    Pass ``None`` to clear (useful for tests). The handler's signature
    is documented above. Each cli_kind has a corresponding expectation:

    - ``dispatch_web_action``: handler routes to
      ``Resonance-Website/tools/action_dispatch.py:dispatch_web_action``.
    - ``shell``: handler routes to ``alethea_mcp_server.exec_shell``.
    - ``python_callable``: handler routes to ``alethea_mcp_server.exec_python``.

    All three handlers must append the dispatch to the action-log so the
    SPEC-099 parity probe + the action-log-bound history_node see the
    entry. The substrate primitive does NOT do the append itself — that
    is the host's job (the host owns the action-log path).
    """
    global _DISPATCH_HANDLER
    _DISPATCH_HANDLER = handler


def get_dispatch_handler() -> Optional[Callable[[str, str, Dict[str, Any]], tuple[bool, str, str]]]:
    """Read back the registered handler (testing + introspection)."""
    return _DISPATCH_HANDLER


# ---------------------------------------------------------------------------
# Verb dispatch (submit / get_state / set_visibility)
# ---------------------------------------------------------------------------
#
# All verbs follow the engine.actions.dispatch_action shape: payload
# dict in, state-delta dict out. The delta includes per-verb trace
# entries so the text-API driver can enumerate recent verb invocations.


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    if action_name == "submit":
        return _handle_submit(state, payload)
    if action_name == "get_state":
        return _handle_get_state(state, payload)
    if action_name == "set_visibility":
        return _handle_set_visibility(state, payload)
    return None


def _handle_submit(state: Dict[str, Any], payload: Dict[str, Any]) -> Dict[str, Any]:
    """Accept a typed command; dispatch through the configured CLI kind.

    Payload shape: ``{text: "<typed-input>", args: {...}?}``. ``args``
    overrides the state's cli_args_schema defaults; ``text`` is the
    primary positional input. The dispatch handler is invoked with
    ``(cli_kind, endpoint, {"text": text, "args": merged_args,
    "natural_language": state.get("cli_natural_language")})``.

    Result is recorded in:
    - ``last_input`` — the typed text.
    - ``last_output`` — the handler's output string (or error message
      when the handler returned success=False).
    - ``history`` — appended ``{input, output, success, kind, endpoint,
      ts: "<from-payload-if-present>"}`` entry; bounded at 1024
      entries (oldest dropped) so a long-running terminal doesn't
      grow unbounded in state.
    - ``last_submit`` — trace dict with the result.

    When ``cli_natural_language: True`` AND the handler is the
    `dispatch_web_action` kind, the typed text is passed verbatim with
    the ``natural_language: True`` flag — the host's handler is
    responsible for invoking the NL router (currently the existing
    `submit_terminal_command` logic; migration in the chat + bottom-
    terminal compositions per arc handoff Section 4.6). The substrate
    primitive provides the SHAPE; the host provides the implementation.

    When no dispatch handler is registered (tests), ``submit`` records
    a no-op trace + a NOT-DISPATCHED success=False so the test can
    verify the substrate-level state transitions without the host.
    """
    text = payload.get("text", "")
    if not isinstance(text, str):
        text = str(text)

    args = payload.get("args", {})
    if not isinstance(args, dict):
        args = {}

    merged_args = dict(state.get("cli_args_schema", {}))
    merged_args.update(args)

    cli_kind = state.get("cli_kind", "dispatch_web_action")
    endpoint = state.get("cli_endpoint", "")
    natural_language = bool(state.get("cli_natural_language", False))

    dispatch_payload = {
        "text": text,
        "args": merged_args,
        "natural_language": natural_language,
    }

    handler = _DISPATCH_HANDLER
    if handler is None:
        success, message, output = (
            False,
            "no dispatch handler registered",
            "",
        )
    else:
        try:
            result = handler(cli_kind, endpoint, dispatch_payload)
        except Exception as exc:  # noqa: BLE001
            success, message, output = (
                False,
                f"dispatch handler raised: {type(exc).__name__}: {exc}",
                "",
            )
        else:
            success, message, output = _normalize_handler_result(result)

    ts = str(payload.get("ts") or "")
    history_entry = {
        "input": text,
        "output": output,
        "success": success,
        "kind": cli_kind,
        "endpoint": endpoint,
        "ts": ts,
        "message": message,
    }
    history = list(state.get("history") or [])
    history.append(history_entry)
    # Bound the history at 1024 entries so a long-running terminal
    # doesn't grow unbounded. The action-log on the host side is the
    # canonical long-term store; this in-state history is a working
    # window the text-API driver inspects.
    if len(history) > 1024:
        history = history[-1024:]

    state["last_input"] = text
    state["last_output"] = output
    state["history"] = history
    return {
        "last_input": text,
        "last_output": output,
        "history": history,
        "last_submit": {
            "submitted": True,
            "success": success,
            "message": message,
            "output": output,
            "kind": cli_kind,
            "endpoint": endpoint,
            "natural_language": natural_language,
        },
    }


def _handle_get_state(state: Dict[str, Any], payload: Dict[str, Any]) -> Dict[str, Any]:
    """Read back the terminal's current state. Pure read; no mutation."""
    return {
        "last_get_state": {
            "visibility": state.get("visibility", "compact"),
            "last_input": state.get("last_input", ""),
            "last_output": state.get("last_output", ""),
            "history_len": len(state.get("history") or []),
            "cli_kind": state.get("cli_kind", "dispatch_web_action"),
            "cli_endpoint": state.get("cli_endpoint", ""),
            "input_node": state.get("input_node", ""),
            "output_node": state.get("output_node", ""),
            "history_node": state.get("history_node", ""),
        }
    }


def _handle_set_visibility(state: Dict[str, Any], payload: Dict[str, Any]) -> Dict[str, Any]:
    """Set the terminal's visibility (hidden / compact / expanded).

    When ``payload['visibility']`` is omitted OR == "cycle", the
    visibility advances to the next state in the cycle (hidden ->
    compact -> expanded -> hidden). This matches the existing
    bottom-terminal renderer's toggle-button behavior so a composed
    toggle-button can dispatch `set_visibility(cycle)` without
    knowing the current state.

    Invalid visibilities are clamped to "compact" and the delta
    surfaces the clamp via `last_set_visibility.clamped=True` so the
    LLM-driver notices the mistake.
    """
    requested = payload.get("visibility", "cycle")
    if requested == "cycle" or requested is None:
        current = state.get("visibility", "compact")
        try:
            idx = VISIBILITIES.index(current)
        except ValueError:
            idx = VISIBILITIES.index("compact")
        new_visibility = VISIBILITIES[(idx + 1) % len(VISIBILITIES)]
        clamped = False
    elif requested in VISIBILITIES:
        new_visibility = requested
        clamped = False
    else:
        new_visibility = "compact"
        clamped = True

    state["visibility"] = new_visibility
    return {
        "visibility": new_visibility,
        "last_set_visibility": {
            "visibility": new_visibility,
            "requested": requested,
            "clamped": clamped,
        },
    }


# ---------------------------------------------------------------------------
# Internal: handler-result normalization
# ---------------------------------------------------------------------------


def _normalize_handler_result(result: Any) -> tuple[bool, str, str]:
    """Coerce a handler's return into (success, message, output).

    Accepts:
    - 3-tuple (success, message, output) — passed through.
    - 2-tuple (success, message) — output set to message.
    - dict with keys success/message/output — extracted.
    - bool — success-only; message + output empty.
    - str — assumed success=True; output is the string.

    Defensive normalization keeps the host-handler contract loose
    (handlers can return whatever shape they prefer) without forcing
    every host to construct a strict 3-tuple. Unknown shapes fall back
    to (False, "<type repr>", "").
    """
    if isinstance(result, tuple):
        if len(result) == 3:
            success, message, output = result
            return bool(success), str(message), str(output)
        if len(result) == 2:
            success, message = result
            return bool(success), str(message), str(message)
    if isinstance(result, dict):
        success = bool(result.get("success", True))
        message = str(result.get("message", ""))
        output = str(result.get("output", message))
        return success, message, output
    if isinstance(result, bool):
        return result, "", ""
    if isinstance(result, str):
        return True, "", result
    return False, f"unrecognized handler result shape: {type(result).__name__}", ""
