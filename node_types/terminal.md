---
name: TerminalNode
kind: node-type-manifest
spec: SPEC-303
version: 1.0
status: shipped
landed: 2026-05-24
source_arc: ../../../Alethea/session_types/handoffs/2026_05_23_website_mvp_misframing_recovery.md
maintainer_directive_verbatim: |
  "the terminal being a specific node that can be linked to a text box node such
  that I can have rectangle -> text + scroll bar -> terminal and the text in
  the box is then determined full by the logic of a CLI."
---

# TerminalNode — CLI-as-substrate-primitive

The terminal substrate primitive that unblocks the chat + bottom-terminal
GUI-builder compositions per the website-MVP misframing recovery arc
(2026-05-23). Not a renderer — a substrate node-type that hosts CLI logic
and LINKS to text-box nodes for input / output / history.

## Why this is a substrate primitive, not a rendered widget

Per the maintainer's closing-turn verbatim and the closing audit's
compose-not-build-bespoke filter (audit §4.2): a terminal that emitted
its own HTML would collapse three perspectival nodes (terminal CLI,
text-box display, scroll-bar viewport) into one bespoke renderer,
repeating the misframing the recovery arc is fixing. By landing as a
substrate node-type with no visual emit, the terminal becomes one
primitive among many that the maintainer composes against in the GUI
builder. The composition shape `rectangle → text + scroll bar →
terminal` (maintainer verbatim) reads as: BoxNode + (TextBoxNode +
ScrollBarNode) + (TerminalNode LINKED via `binding.output_node`). The
text in the text-box is determined fully by the CLI logic the terminal
hosts.

## Contract

See the SPEC-303 entry in `Alethea/specifications/README.md` for the
canonical spec. Summary:

- **kind** in substrate frontmatter: `terminal`
- **body-format** in substrate frontmatter: `terminal-spec`
- **Body JSON shape** (per arc handoff Section 4.1):
  ```json
  {
    "name": "<terminal-name>",
    "cli": {
      "kind": "dispatch_web_action" | "shell" | "python_callable",
      "endpoint": "<endpoint-or-handle>",
      "args_schema": { ... },
      "natural_language": true | false
    },
    "binding": {
      "input_node": "<text-box-node-id-OR-link-handle>",
      "output_node": "<text-box-node-id-OR-link-handle>",
      "history_node": "<text-box-or-list-node-id-OR-link-handle>"
    },
    "view_state": {
      "visibility": "hidden" | "compact" | "expanded",
      "polling_interval_ms": 500
    }
  }
  ```

## CLI kinds

Three dispatch routes; all three append to the same action-log and
respect the SPEC-099 parity probe.

| `cli.kind` | Routes to | Use case |
|---|---|---|
| `dispatch_web_action` | `Resonance-Website/tools/action_dispatch.py:dispatch_web_action` (SPEC-097) | Chat / bottom-terminal — the typed text dispatches against a renderer-node's `handle_action` |
| `shell` | `alethea_mcp_server.exec_shell` | Debug terminal — typed shell commands |
| `python_callable` | `alethea_mcp_server.exec_python` | Substrate-inspector terminal — Python eval against the corpus |

The actual host-binding to these endpoints happens via
`set_dispatch_handler(handler)` at composition time (see the docstring
in `terminal.py`). The substrate primitive itself does NOT import any
host MCP / HTTP code — it remains testable in isolation.

## Verbs

| Verb | Payload | Effect |
|---|---|---|
| `submit` | `{text: str, args: dict?, ts: str?}` | Route the typed input through the configured `cli_kind` handler. Records `last_input` / `last_output` / appended `history` entry / `last_submit` trace. |
| `get_state` | `{}` | Read back visibility + last input/output/history-len + binding ids. Pure read. |
| `set_visibility` | `{visibility: hidden\|compact\|expanded\|cycle?}` | Set visibility. Omitting or passing `"cycle"` advances to next state (hidden → compact → expanded → hidden). Invalid values clamp to `compact` with `clamped=True` in the delta. |

## Composition pattern (maintainer's verbatim)

```
rectangle → text + scroll bar → terminal
```

Read as: a BoxNode at the outer layer; a TextBoxNode + ScrollBarNode
composed inside; a TerminalNode LINKED via `binding.output_node` to the
TextBoxNode. The text in the TextBoxNode is then determined fully by
the logic of the CLI the terminal hosts. Three perspectival nodes; one
composition; zero bespoke renderers required.

## Deferred wiring (arc handoff §4.6)

The existing natural-language router inside `Resonance-Website/tools/
action_dispatch.py:submit_terminal_command` is NOT migrated by this PR.
The terminal primitive ships with the `cli_natural_language: true` flag
and the SHAPE for the host to invoke a NL router on submit, but the
actual `submit_terminal_command` NL logic stays where it is. The chat +
bottom-terminal migrations (next arcs) will move that logic into the
terminal node's dispatch path. This separation lets the substrate
primitive land + be tested + be composed against before the migration
that consumes it.

## Tests

Apeiron-side: `Apeiron/tests/test_terminal_node.py` (node-type
registration, build defaults, link semantics, verb dispatch).

Alethea-side: `Alethea/Alethea-cc/tests/test_terminal_body_format.py`
(body-format `terminal-spec` validation, all three `cli.kind` paths
exercised through the substrate `execute()` flow).

## Cross-references

- SPEC-303: `Alethea/specifications/README.md`
- Arc handoff: `Alethea/session_types/handoffs/2026_05_23_website_mvp_misframing_recovery.md` Section 4
- Closing audit: `Alethea/notes/website_planning_arc/audits/closing_audit_2026_05_23_misframing.md`
- Existing dispatch infrastructure (unchanged): `Resonance-Website/tools/action_dispatch.py`, `Resonance-Website/tools/action_log.py`, `Resonance-Website/tools/terminal_bridge.py`
