# Apeiron desktop-shortcut installer. Closes the remaining manual step
# named in SPEC-001's implementation pointer: automated install that
# creates the desktop shortcut on first run so the maintainer doesn't
# right-click the .bat and drag the link by hand.
#
# Run from the Apeiron repo root or from anywhere with the repo path on
# the command line:
#
#     powershell -ExecutionPolicy Bypass -File scripts\create_desktop_shortcut.ps1
#
# Idempotent: running twice overwrites the existing shortcut with the
# current values. Safe to re-run after every git pull.

[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [string]$ShortcutName = "Apeiron"
)

if ([string]::IsNullOrEmpty($RepoRoot)) {
    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrEmpty($scriptDir)) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    $RepoRoot = (Resolve-Path (Join-Path $scriptDir "..")).Path
}

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
$LauncherBat = Join-Path $RepoRoot "scripts\launch_apeiron.bat"
$IconCandidate = Join-Path $RepoRoot "scripts\apeiron.ico"

if (-not (Test-Path $LauncherBat)) {
    throw ("launch_apeiron.bat not found at " + $LauncherBat + " (check -RepoRoot)")
}

$DesktopDir = [Environment]::GetFolderPath("Desktop")
$ShortcutPath = Join-Path $DesktopDir ($ShortcutName + ".lnk")

$WScriptShell = New-Object -ComObject WScript.Shell
$Shortcut = $WScriptShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = $LauncherBat
$Shortcut.WorkingDirectory = $RepoRoot
$Shortcut.WindowStyle = 1   # Normal window
$Shortcut.Description = "Launch the Apeiron workflow surface."
if (Test-Path $IconCandidate) {
    $Shortcut.IconLocation = ($IconCandidate + ",0")
}
$Shortcut.Save()

Write-Output ("Created: " + $ShortcutPath)
Write-Output ("Target:  " + $LauncherBat)
Write-Output ("Working: " + $RepoRoot)
