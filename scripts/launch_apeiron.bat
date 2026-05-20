@echo off
REM Apeiron one-click launcher (Windows). SPEC-001 (one-click GUI launch) +
REM SPEC-065 (2D Tk workflow shell is the default).
REM
REM Right-click this .bat -> "Create shortcut" -> drag the shortcut to the
REM Desktop. Right-click the desktop shortcut -> Properties -> change the
REM icon to scripts\apeiron.ico if/when one is added. Double-click to
REM open the Apeiron workflow surface.
REM
REM What this does:
REM   1. cd's to the Apeiron repo root.
REM   2. Runs `python -m tools.workflow_gui --scene workflow_view.json`,
REM      which boots the engine, spawns the default workflow-management
REM      session (per SPEC-002 / SPEC-003), and opens the 2D Tk workflow
REM      GUI with sidebar tabs + scrollable central pane + chat input
REM      (per SPEC-065). The 3D tab inside the GUI embeds the realtime
REM      renderer in the central pane.
REM
REM Power users who want the terminal REPL can run:
REM     python -m tools.workflow --scene workflow_view.json
REM
REM directly from the repo root.

setlocal
cd /d "%~dp0\.."
python -m tools.workflow_gui --scene workflow_view.json
endlocal
