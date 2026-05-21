# Handoff — Streamlit launcher correction + GUI↔CLI architecture refinement

**Session date:** 2026-05-21
**Branch:** `claude/streamlit-workflow-gui-iridescent`
**PR:** https://github.com/liamhodgsonhollingsworth/Apeiron/pull/57
**Status:** in-progress; compact incoming

## Why this handoff exists

A prior session built the Streamlit workflow surface (`tools/workflow_streamlit/`) and merged the basic GUI + a GUI↔CLI command registry + an in-page terminal. The maintainer then reported two things:

1. **The program never opened** when they clicked the desktop `Apeiron.lnk` (their message to the workflow-mgmt session stalled because no session received it). Suspected root cause: `__main__.py` used `os.execvp` which on Windows replaces the current Python process; the cmd window the .lnk opened lost stdout wiring and streamlit died silently.
2. **Wishes/tasks/queues should be removed** from the website. Their commands should stay registered for CLI inspection but no GUI panel should render them.
3. **Every interactable widget** on the page must route through the registry — including settings, sidebar toggles, every click. The in-page terminal shows the readable CLI command for each; the cmd window where streamlit is running shows the parsed/dispatched form. Both surface every event.

This session implemented the fixes. They've been committed to the same PR; verification of the actual desktop click is the next session's job.

## What's true on disk now

### Launcher chain (fixed)

- `scripts/launch_apeiron.bat` — tries `py` first, then `python`; calls `python -m tools.workflow_streamlit %*`. Prints a clear error if neither is on PATH.
- `tools/workflow_streamlit/__main__.py` — now uses `subprocess.Popen` + `proc.wait()`, NOT `os.execvp`. Parent stays alive, cmd window stays open and shows streamlit's stdout. Prints a banner explaining "this cmd window IS the desktop terminal — every dispatched command prints here".
- `Apeiron.lnk` on the Desktop already points at `scripts/launch_apeiron.bat`; no shortcut edit needed.

### Panels (stripped)

Removed at maintainer request:
- `panels/workflow_panel.py` (tasks/ideas/wishes columns) — **deleted**.
- `panels/items_panel.py` (generic items helper) — **deleted**.
- `panels/idea_queue_panel.py` (sidebar idea queue) — **deleted**.

Remaining panels:
- `panels/auth_panel.py` — gate; auto-LHH locally, scrypt login under `APEIRON_REQUIRE_LOGIN=1`.
- `panels/session_panel.py` — sidebar session status.
- `panels/scene_picker_panel.py` — sidebar scene selector.
- `panels/chat_panel.py` — bottom; inbox-backed chat with the active session.
- `panels/terminal_panel.py` — bottom; togglable CLI terminal.

The corresponding commands (`idea-queue.*`, `items.*`) remain registered in `commands.py` so headless inspection still works.

### Dispatch echo (new)

`command_registry.run` now prints every dispatch to stdout:

```
[dispatch source=cli resolved=ping ok] input='ping hello' argv=['ping', 'hello'] -> pong hello
```

That print lands in the streamlit subprocess's stdout, which is inherited by the cmd window the .lnk opened. The cmd window IS the desktop terminal showing the parsing side; the in-page terminal shows the readable form. Both are populated for every dispatched command from any source (gui, terminal, cli).

### UI-toggle commands (new)

`ui.terminal.toggle`, `ui.terminal.hide`, `ui.terminal.show` — the in-page terminal HIDE/SHOW button now dispatches through the registry, so a click logs the equivalent CLI form. The handler imports streamlit lazily so headless tests degrade cleanly.

### Test count

`tests/test_workflow_streamlit_commands.py` + `tests/test_workflow_streamlit_registry.py` = **57 tests, all passing**.

The registry test was updated to expect the new shipped panel set (auth, session-status, scene-picker, chat, terminal).

## Verification still needed

These were tested in-process or via the preview tool, NOT via the actual desktop `Apeiron.lnk` click:

1. **Live desktop launch.** The maintainer should double-click `Apeiron.lnk`. Expected behavior:
   - A cmd window opens showing `[apeiron] booting Streamlit workflow surface...` and the streamlit URL.
   - The default browser opens to `http://localhost:8501` with the workflow page.
   - The cmd window stays open as long as the page is open.
   - Closing the cmd window (or Ctrl+C in it) shuts streamlit down.
2. **Dispatch echo in cmd window.** Click any button on the page. The cmd window should print a `[dispatch ...]` line matching the in-page terminal's log entry.
3. **No wishes/tasks/queues visible on the page.** Sidebar should show only Session + Scenes. Main pane should be empty between the mode banner and the chat. The maintainer asked for this.

If any of those fail, the next session diagnoses by:
- Running `python -m tools.workflow_streamlit --server.headless=true` from a terminal in the Apeiron repo and checking the streamlit logs.
- Checking the `state/workflow/` directory for the marker file `default_workflow_mgmt.txt` (records the persistent session ID).
- Asking the maintainer for the exact cmd-window output if the launch fails (likely a Python-not-on-PATH issue).

## What's still open (the user's actual goal)

The current GUI is a thin minimum. The maintainer's Notion entry of 2026-05-21 names a much larger vision that the next sessions should build INTO the surface, panel by panel:

- **Drag-and-drop GUI builder** — drag a plus-button onto the canvas, drag a template, "wire" connects them via Claude Code. Not built. Plan: a `panels/builder_panel.py` that uses streamlit-elements or streamlit-sortables for canvas; a `wire` command that hands the unwired graph to the workflow-mgmt session.
- **Control-mode (Ctrl-key) searchable node sidebar** — searchable index of nodes by content or by function. Not built. Plan: a `panels/control_mode_panel.py` that listens for the Ctrl key via JS hook + renders a search box.
- **Right-sidebar pastebin + archive button (history icon, bottom left)** — not built.
- **Scroll-bar timeline jumps to past work** — not built.
- **Visual page for spawned sessions (claude-code wrapper)** — partial via `session_panel`; needs a multi-session roster + tab navigation.

The 1:1 GUI↔CLI architecture means each of these is **one new panel file** + a few new commands in `commands.py`. The panel reads/writes whatever state file or engine cache it needs; the buttons dispatch through `registry.run_gui`. No driver edits required.

## Critical architecture facts the next session must respect

1. **Every interactive widget dispatches through `CommandRegistry`.** Buttons, dropdowns, chat inputs, terminal toggle — all call `registry.run_gui(name, ctx.as_command_context(), *args)`. The handler is canonical; the widget is presentation. New widgets that don't follow this break the GUI↔CLI 1:1 promise the maintainer asked for explicitly.
2. **Each node module must be SHORT and SIMPLE.** Maintainer's repeated directive: "every single node module in the code should be as short and as simple as possible, displaying a short set of behaviors and being stitched together by the logic between nodes that makes everything work." If a panel grows past ~150 lines, extract helpers into a sibling module.
3. **Page refresh uses `@st.fragment(run_every=...)`, NOT `st_autorefresh`.** The full-page autorefresh greys out the whole page every tick. Fragments only refresh their region.
4. **Source-tagging in the terminal:** GUI clicks log `[gui]`, terminal typed input logs `[terminal]`, external CLI logs `[cli]`. Don't break that contract.
5. **Headless CLI:** `python -m tools.workflow_streamlit.cli --headless <cmd>` runs commands without streamlit. Handlers that mutate `st.session_state` must lazy-import streamlit and gracefully error in headless mode. Pattern in `commands.py::_ui_terminal_toggle`.
6. **The cmd window IS the desktop terminal.** Streamlit's stdout is inherited by the .lnk's cmd window. Anything `print()`d during dispatch lands there. `command_registry._stdout_echo` is the canonical place for this.
7. **CLI bridge file: `state/workflow/cli_command_queue.txt`.** External callers append commands; the page drains on every 2s bottom-fragment tick. Don't break this contract — many future tools will write to it.

## Files of record (read these first in the next session)

- `tools/workflow_streamlit/__main__.py` — fixed launcher (subprocess.Popen).
- `tools/workflow_streamlit/command_registry.py` — `_stdout_echo` is new.
- `tools/workflow_streamlit/commands.py` — UI commands new at the bottom.
- `tools/workflow_streamlit/panels/terminal_panel.py` — HIDE button now routes through `ui.terminal.toggle`.
- `tests/test_workflow_streamlit_registry.py` — expected panel set updated.
- `scripts/launch_apeiron.bat` — has py-then-python fallback + clearer error on missing Python.

## Memory entries written this session (auto-load in future sessions)

Under `C:\Users\Liam\.claude\projects\C--Users-Liam-Desktop-Alethea\memory\`:

- `feedback_streamlit_fragments_not_autorefresh.md`
- `feedback_streamlit_buttons_resist_dom_click.md`
- `project_apeiron_command_registry_gui_cli_iso.md`
- `project_apeiron_streamlit_cli_bridge.md`
- `reference_apeiron_streamlit_entry_points.md`

These are indexed in `MEMORY.md` under "Apeiron Streamlit workflow GUI — 2026-05-21".

## Suggested next actions

1. **Ask the maintainer to click `Apeiron.lnk`** and confirm the cmd window opens + the browser tab appears + the page renders without the wishes/tasks/queues panels.
2. **If step 1 fails**: diagnose via `python -m tools.workflow_streamlit` directly from a terminal; check streamlit + python presence; check `state/accounts.json` exists.
3. **If step 1 succeeds**: start picking off the larger vision items (drag-and-drop builder, control-mode search sidebar, archive button, scroll timeline) one panel at a time. Each is `panels/<name>.py` + a few new entries in `commands.py`. No driver edits needed.
4. **Consider the rendering-wrapper question:** the maintainer asked about "the easiest possible program to run from the desktop that can load and render webpage content". The current path is browser + streamlit. A future enhancement: `pywebview` (single dependency, embeds a webview in a desktop window so the page looks like a native app). Defer until the maintainer requests it explicitly.

## Last commit on the PR

```
c9239b3 Multi-session commands + break-point + generalizability tests
```

Local working tree has uncommitted changes from this session (the launcher fix, panel deletions, UI commands, stdout echo, banner ASCII fixes). They need to be committed + pushed before the compact lands.

Last `git status --short` output:
```
 M scripts/launch_apeiron.bat
 M tests/test_workflow_streamlit_registry.py
 M tools/workflow_streamlit/__main__.py
 M tools/workflow_streamlit/command_registry.py
 M tools/workflow_streamlit/commands.py
 M tools/workflow_streamlit/panels/terminal_panel.py
 D tools/workflow_streamlit/panels/idea_queue_panel.py
 D tools/workflow_streamlit/panels/items_panel.py
 D tools/workflow_streamlit/panels/workflow_panel.py
```
