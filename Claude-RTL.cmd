@echo off
REM =============================================================================
REM Claude RTL -- one-click per-session helper
REM =============================================================================
REM Copies the RTL injection snippet to the clipboard and launches Claude.
REM After Claude opens, DevTools auto-opens (because CLAUDE_DEV_TOOLS=detach
REM is set as a user env var). Click the Console tab, then Ctrl+V then Enter.
REM
REM Pin this file to taskbar / start menu for one-click access.
REM =============================================================================

setlocal

REM Resolve the directory this .cmd lives in
set "ROOT=%~dp0"

REM 1. Copy snippet to clipboard via PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-Content '%ROOT%scripts\inject-snippet.js' -Raw -Encoding UTF8 | Set-Clipboard"

if errorlevel 1 (
    echo [Claude-RTL] Failed to copy snippet to clipboard.
    pause
    exit /b 1
)

REM 2. Launch Claude via the Microsoft Store activation framework. The
REM    CLAUDE_DEV_TOOLS env var is inherited from the user environment,
REM    so DevTools opens automatically.
start "" "shell:AppsFolder\Claude_pzs8sxrjxfjjc!Claude"

echo [Claude-RTL] Snippet on clipboard. Claude launching.
echo [Claude-RTL] When DevTools opens: Console tab, Ctrl+V, Enter.

endlocal
