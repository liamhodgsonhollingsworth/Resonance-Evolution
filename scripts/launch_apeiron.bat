@echo off
REM Apeiron one-click launcher (Windows). SPEC-001 (one-click GUI launch).
REM
REM Boots the Streamlit workflow surface — the browser-rendered GUI that
REM is the local-launch counterpart of the eventual Resonance website
REM workflow surface. Same engine + sessions + inbox primitives as the
REM Tk GUI and terminal REPL; the renderer is the only difference.
REM
REM Right-click this .bat -> "Create shortcut" -> drag the shortcut to
REM the Desktop. (The existing Apeiron.lnk on the Desktop already points
REM at this file, so updating the .bat updates the shortcut behavior.)
REM
REM What this does:
REM   1. cd's to the Apeiron repo root.
REM   2. Runs `python -m tools.workflow_streamlit`, which boots the
REM      engine + auto-spawns the default workflow-management session
REM      + opens the Streamlit page in the default browser.
REM
REM Other surfaces, kept available for power users:
REM   * Terminal REPL:  python -m tools.workflow --scene workflow_view.json
REM   * Tk GUI:         python -m tools.workflow_gui --scene workflow_view.json

setlocal
cd /d "%~dp0\.."
python -m tools.workflow_streamlit %*
endlocal
