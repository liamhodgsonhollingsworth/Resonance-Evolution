# Workflow shell

Interactive Python shell that hosts the workflow-from-within-Apeiron loop. The chat surface for talking to Claude Code sessions from inside Apeiron, with live hot-reload of node-types as sessions write them. The text-API rendering of the workflow surface; the 3D rendering arrives when [wishlist #023](../../wishlist.md#tier-d--dream-mode-core-features) (realtime renderer) lands.

## Quick start

From the Apeiron repo root, with `claude` on PATH:

    python -m tools.workflow --scene workflow_view.json

Once at the prompt, try this end-to-end loop:

    workflow [*]> /spawn parallel-development worker -- build a Clock node-type that renders the wall clock as a small Cube whose color shifts with the second hand
    workflow [a1b2c3d4]> /list types

After the worker writes `node_types/clock.py`, the file-watcher fires and you see:

    [fwatch new Clock node_types/clock.py]

Now use it without restarting:

    workflow [a1b2c3d4]> /dispatch spawn Clock my_clock
    workflow [a1b2c3d4]> /dispatch render TextRenderer 0,0,5

## Commands

| Command | What it does |
|---------|--------------|
| `/help` | List every command. |
| `/list [sessions\|types\|nodes\|inbox]` | List sessions / node-types / live nodes / inbox messages. |
| `/spawn <type> [name] [-- seed]` | Spawn a Claude Code session in stream-json mode. |
| `/target <session\|none>` | Route bare-text input to this session. `none` clears. |
| `/send <session> <message>` | Send a message to a specific session. |
| `/wish <description>` | Submit a feature request to the active session. Auto-spawns a worker if none active. The session is told the file-watcher will hot-reload its new files. |
| `/inbox [unread\|to <addr>\|post ...]` | Inspect the file-based inbox. `post <to> <kind> <summary> [-- body]` writes a message. |
| `/render <renderer> <viewer_path>` | Render via a registered renderer (TextRenderer, AsciiDebug, etc.). |
| `/types` | List currently-registered node-types. |
| `/nodes` | List live spawned nodes in the scene. |
| `/dispatch <cmd ...>` | Dispatch a text-API command (the same grammar as `tools/text_test.py`). |
| `/reload <type>` | Manually hot-reload a node-type module. |
| `/archive <session>` | Archive a session (terminate + persist). |
| `/quit` | Exit. Sessions persist on disk for resume. |

Bare text (no leading `/`) is sent to the currently-targeted session.

## How it works

Three Python modules compose the surface:

- [`session_manager.py`](session_manager.py) — Python sibling of the cockpit's TypeScript SessionManager. Spawns `claude` subprocesses with `--print --output-format stream-json --input-format stream-json --include-partial-messages --verbose --permission-mode auto --session-id <uuid>`. Reader threads multiplex stdout into three logical channels: `communication` (assistant text), `activity` (tool calls + lifecycle + unknown event types), `diagnostic` (raw stream-json appended to `state/raw_logs/<id>.jsonl`).
- [`inbox.py`](inbox.py) — file-based message queue. Wire-compatible with the Alethea-cc `nodes/inbox_msg_*.md` convention. Auto-detects a sibling Alethea-cc checkout and writes messages into the shared `nodes/` directory by default. Sessions and the shell share one inbox; the only difference is the processing step (shell reads via `Inbox.list_all()`; sessions read via their MCP-wrapped `inbox_read` tool).
- [`shell.py`](shell.py) — interactive REPL. Boots `Engine(root_dir).discover()`, optionally `load_scene(scene)`, starts `FileWatcher(engine, on_event=shell.on_file_event)`. Background thread reads stdin so asynchronous events (session text, fwatch events, inbox arrivals) print to stdout without blocking on user typing.

## Runtime state

Lives under `state/` (gitignored):

- `state/workflow/sessions/<uuid>.json` — persistent session records. Re-running the shell hydrates them as `idle` until `/send` reactivates via `--resume`.
- `state/workflow/raw_logs/<uuid>.jsonl` — raw stream-json events per session for post-hoc diagnosis of CLI schema drift.
- `state/workflow/archive/` — archived session records.
- `state/workflow/inbox/` — local fallback when no Alethea-cc checkout is present.
- `state/workflow/inbox_read.txt` — read-receipts log.

## Environment variables

- `CLAUDE_BIN` — path to the `claude` CLI (default: auto-detected on PATH).
- `ALETHEA_CC_ROOT` — path to the Alethea-cc checkout for shared inbox (default: auto-detected by walking parents of cwd).

## Testing

The test suite at [`tests/test_workflow_*.py`](../../tests/) covers SessionManager (against a fake-claude fixture so real `claude` isn't needed), Inbox roundtrip, and the load-bearing end-to-end demo where a session writes a node-type and the file-watcher registers it without restart.

    python -m pytest tests/test_workflow_inbox.py tests/test_workflow_session_manager.py tests/test_workflow_end_to_end.py -v

## Related

- [design/workflow_from_within_apeiron.md](../../design/workflow_from_within_apeiron.md) — the feasibility + plan page. The Phase 3 addendum names what this directory delivers.
- The cockpit (TypeScript Electron app, in the `nervous-lalande-93b4ea` Alethea worktree) is an alternative rendering of the same surface against the same primitives. When the cockpit merges, both renderings drive the same Apeiron engine.
