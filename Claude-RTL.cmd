@echo off
REM =============================================================================
REM Claude RTL -- one-click per-session helper
REM =============================================================================
REM Copies the RTL injection snippet to the clipboard and launches Claude with
REM LTR window chrome (--lang=en-US --force-ui-direction=ltr). On Hebrew/Arabic
REM Windows display languages this avoids the mirrored-window bug where the
REM embedded browser/preview pane draws a duplicate "ghost" layer over the chat.
REM
REM After Claude opens, DevTools auto-opens (because CLAUDE_DEV_TOOLS=detach
REM is set as a user env var). Click the Console tab, then Ctrl+V, then Enter.
REM
REM Pin this file to taskbar / start menu for one-click access.
REM =============================================================================

setlocal
set "ROOT=%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%claude-rtl.ps1" -Mode LaunchLtr
if errorlevel 1 pause

endlocal
