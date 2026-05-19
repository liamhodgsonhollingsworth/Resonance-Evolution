@echo off
REM Apeiron one-click launcher (Windows). SPEC-001 (one-click GUI launch).
REM
REM Right-click this .bat -> "Create shortcut" -> drag the shortcut to the
REM Desktop. Right-click the desktop shortcut -> Properties -> change the
REM icon to scripts\apeiron.ico if/when one is added. Double-click to
REM open the Apeiron workflow surface.
REM
REM What this does:
REM   1. cd's to the Apeiron repo root.
REM   2. Runs `python -m tools.workflow --scene workflow_view --launch-realtime`,
REM      which boots the engine, spawns the default workflow-management
REM      session (per SPEC-002 / SPEC-003), and opens the realtime
REM      window with the workflow_view scene.
REM
REM The workflow shell stays attached to this terminal — typing into the
REM terminal sends to the active chat session per SPEC-002. The realtime
REM window shows the panels; close the window with X to return to the
REM shell alone.

setlocal
cd /d "%~dp0\.."
python -m tools.workflow --scene workflow_view --launch-realtime
endlocal
