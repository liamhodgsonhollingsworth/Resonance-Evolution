@echo off
REM Apeiron desktop launcher — boots the Streamlit workflow surface.
REM
REM Apeiron.lnk on the Desktop points here. Double-click opens this
REM cmd window, which is the "desktop terminal" the maintainer asked
REM for: it shows the non-readable parsing side of every dispatched
REM command. Streamlit's own page is the readable side, shown in the
REM browser tab that opens automatically.
REM
REM Power-user alternatives:
REM   python -m tools.workflow         (terminal-only REPL)
REM   python -m tools.workflow_gui     (legacy Tk GUI)

setlocal
cd /d "%~dp0\.."

REM Try the Python Launcher first (`py` is bundled with the standard
REM Windows Python installer and respects shebangs), then plain
REM `python`, then warn the user clearly.
where py >nul 2>nul
if %errorlevel% == 0 (
    py -m tools.workflow_streamlit %*
    goto end
)
where python >nul 2>nul
if %errorlevel% == 0 (
    python -m tools.workflow_streamlit %*
    goto end
)
echo.
echo [apeiron] could not find Python on PATH.
echo [apeiron] install Python 3.11+ (and tick "Add to PATH") or check
echo [apeiron] `py` from the Python Launcher for Windows is available.
echo.
pause

:end
endlocal
