<#
.SYNOPSIS
    Claude RTL Companion -- RTL/Hebrew text rendering for Claude Desktop, safely.

.DESCRIPTION
    Uses Claude Desktop's own officially-shipped "Enable Developer Mode" feature
    (which writes allowDevTools=true to %APPDATA%\Claude\config.json) so that
    Ctrl+Alt+I opens DevTools, then helps you paste a CSS-injection snippet into
    the Console.

    This script does NOT modify any application file, app.asar, MSIX signature,
    Program Files, or anything in WindowsApps\. The only file it ever writes is
    the user-controlled config.json in your roaming profile, and only the single
    "allowDevTools" key inside it. A backup of config.json is created first.

    NOTE: Earlier versions of this script tried --remote-debugging-port via the
    Chrome DevTools Protocol. Electron 30+ strips that flag at the CLI level
    before any JS executes (verified on Claude 1.6608.2.0 / Electron 41.5.0),
    so we now use the in-app developer-mode path instead. It is officially
    supported by the application and persists across Microsoft Store updates.

.PARAMETER Mode
    Status         (default) -- print state of dev mode and Claude.
    Setup          -- one-shot: EnableDevMode + set CLAUDE_DEV_TOOLS env var +
                       broadcast env change to Explorer + copy snippet to
                       clipboard. Non-interactive; safe for automated installs.
    EnableDevMode  -- set allowDevTools=true in config.json (auto-backup).
    DisableDevMode -- remove allowDevTools from config.json.
    CopySnippet    -- copy injection snippet to clipboard + show paste steps.
    PrintSnippet   -- print the snippet to stdout.

.EXAMPLE
    .\claude-rtl.ps1 -Mode Setup
    Recommended for first install. Idempotent and non-interactive. After it
    runs, close Claude completely (including system tray) and reopen.

.EXAMPLE
    .\claude-rtl.ps1
    Show current state (read-only).

.EXAMPLE
    .\claude-rtl.ps1 -Mode CopySnippet
    Copy snippet to clipboard. Switch to Claude DevTools Console, Ctrl+V, Enter.
#>

[CmdletBinding()]
param(
    [ValidateSet('Status','Setup','EnableDevMode','DisableDevMode','CopySnippet','PrintSnippet','LaunchLtr','InstallShortcut','Inject')]
    [string]$Mode = 'Status',

    # Backwards-compat: no-op. Prompts have been removed; the script always
    # proceeds because EnableDevMode/DisableDevMode are reversible, create
    # timestamped backups, and the user already consented by specifying the
    # mode explicitly.
    [switch]$NoConfirm,

    [string]$SnippetPath,

    # Name of the saved DevTools snippet that LaunchLtr's auto-inject runs.
    [string]$SnippetName = 'Claude-RTL'
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
if (-not $SnippetPath) { $SnippetPath = Join-Path $scriptDir 'scripts\inject-snippet.js' }

$ConfigPath = Join-Path $env:APPDATA 'Claude\config.json'

# ============================================================================
# Logging helpers
# ============================================================================
function Write-Info { param($Msg) Write-Host "[claude-rtl] $Msg" -ForegroundColor Cyan }
function Write-Ok   { param($Msg) Write-Host "[claude-rtl] $Msg" -ForegroundColor Green }
function Write-Warn { param($Msg) Write-Host "[claude-rtl] $Msg" -ForegroundColor Yellow }
function Write-Err  { param($Msg) Write-Host "[claude-rtl] $Msg" -ForegroundColor Red }

# ============================================================================
# Discovery
# ============================================================================
function Get-ClaudeDesktopInfo {
    $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue
    if (-not $pkg) {
        throw "Claude Desktop (MSIX) not installed. Install from Microsoft Store first."
    }
    [PSCustomObject]@{
        PackageFamilyName = $pkg.PackageFamilyName
        InstallLocation   = $pkg.InstallLocation
        Version           = $pkg.Version
        UserDataDir       = Join-Path $env:APPDATA 'Claude'
        ConfigPath        = $ConfigPath
    }
}

function Get-RunningClaudeMainProcesses {
    Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -like '*WindowsApps*' -and
            $_.CommandLine -notmatch '--type='
        }
}

function Get-DevToolsState {
    if (-not (Test-Path $ConfigPath)) {
        return [PSCustomObject]@{ ConfigExists = $false; AllowDevTools = $null }
    }
    $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $val = $null
    if ($cfg.PSObject.Properties.Name -contains 'allowDevTools') {
        $val = [bool]$cfg.allowDevTools
    }
    [PSCustomObject]@{
        ConfigExists  = $true
        AllowDevTools = $val
    }
}

# ============================================================================
# config.json edit (the only file we ever write to)
# ============================================================================
function Set-AllowDevTools {
    param([bool]$Enable)

    $cfg = [ordered]@{}
    $configDir = Split-Path -Parent $ConfigPath

    if (-not (Test-Path $configDir)) {
        # Roaming Claude profile doesn't exist yet (Claude was never launched).
        # Create the directory so we can drop a minimal config.json. Claude
        # will read it on first launch and add its own keys.
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        Write-Info "Created profile directory: $configDir"
    }

    if (Test-Path $ConfigPath) {
        # Read as ordered hashtable to preserve key order on round-trip
        $rawJson = Get-Content $ConfigPath -Raw -Encoding UTF8
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $cfg = $rawJson | ConvertFrom-Json -AsHashtable -Depth 32
        } else {
            # PS 5.1 has no -AsHashtable; convert manually preserving order
            $obj = $rawJson | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
        }

        # Backup before write
        $backup = "$ConfigPath.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $ConfigPath -Destination $backup -Force
        Write-Info "Backup written: $backup"
    } else {
        Write-Info "Creating new $ConfigPath (Claude has not launched on this profile yet)."
    }

    if ($Enable) {
        $cfg['allowDevTools'] = $true
    } else {
        if ($cfg.Contains('allowDevTools')) { [void]$cfg.Remove('allowDevTools') }
    }

    $newJson = ($cfg | ConvertTo-Json -Depth 32)
    # Atomic write via temp + Move-Item
    $tmp = "$ConfigPath.tmp"
    [System.IO.File]::WriteAllText($tmp, $newJson, (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
}

# ============================================================================
# Env var management (CLAUDE_DEV_TOOLS) + WM_SETTINGCHANGE broadcast so
# Explorer (and thus newly-launched Claude) picks up the change immediately.
# ============================================================================
$EnvBroadcastSrc = @"
using System;
using System.Runtime.InteropServices;
public static class EnvBroadcast {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
    public static void Notify() {
        UIntPtr result;
        SendMessageTimeout((IntPtr)0xffff, 0x001A, UIntPtr.Zero, "Environment", 0x0002, 5000, out result);
    }
}
"@

function Set-ClaudeDevToolsEnv {
    param([string]$Value)

    if (-not ('EnvBroadcast' -as [type])) {
        Add-Type -TypeDefinition $EnvBroadcastSrc -Language CSharp
    }

    [Environment]::SetEnvironmentVariable('CLAUDE_DEV_TOOLS', $Value, 'User')
    try { [EnvBroadcast]::Notify() } catch { }

    if ($null -eq $Value -or $Value -eq '') {
        Write-Info "Removed CLAUDE_DEV_TOOLS user env var."
    } else {
        Write-Info "Set CLAUDE_DEV_TOOLS = '$Value' (user scope, broadcast to Explorer)."
    }
}

# ============================================================================
# Snippet (clipboard)
# ============================================================================
function Update-RepoQuietly {
    # Self-update: fast-forward pull of this repo so every install runs the
    # latest launcher + snippet without anyone remembering to git pull.
    # Combined with the editor-sync in Invoke-AutoInject, machines maintain
    # themselves. Fails silently: offline, no git, local changes (--ff-only),
    # or a non-repo folder all just skip the update.
    try {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
        if (-not (Test-Path (Join-Path $scriptDir '.git'))) { return }
        $env:GIT_TERMINAL_PROMPT = '0'   # never hang on a credential prompt
        $null = git -C $scriptDir pull --ff-only --quiet
        if ($LASTEXITCODE -eq 0) { Write-Info "Repo self-update: up to date." }
        else { Write-Info "Repo self-update skipped (offline or local changes)." }
    } catch {}
}

function Get-Snippet {
    if (-not (Test-Path $SnippetPath)) {
        throw "Snippet missing: $SnippetPath"
    }
    Get-Content $SnippetPath -Raw -Encoding UTF8
}

function Copy-SnippetToClipboard {
    $snippet = Get-Snippet
    Set-Clipboard -Value $snippet
    Write-Ok "Snippet copied to clipboard ($([Math]::Round($snippet.Length / 1KB, 1)) KB)."
}

# ============================================================================
# Modes
# ============================================================================
function Invoke-StatusMode {
    Write-Info "=== Claude RTL Companion -- Status ==="
    try {
        $info = Get-ClaudeDesktopInfo
        Write-Ok "Claude Desktop v$($info.Version) at $($info.InstallLocation)"
    } catch {
        Write-Err "Claude Desktop not found: $_"
        return
    }

    $procs = @(Get-RunningClaudeMainProcesses)
    if ($procs) {
        Write-Info "Running main process: PID $($procs[0].ProcessId)"
    } else {
        Write-Info "Claude is not running."
    }

    $dt = Get-DevToolsState
    if (-not $dt.ConfigExists) {
        Write-Warn "config.json not found at $ConfigPath -- launch Claude once to create it."
    } elseif ($dt.AllowDevTools -eq $true) {
        Write-Ok  "allowDevTools = true   (DevTools should open with Ctrl+Alt+I)"
    } elseif ($dt.AllowDevTools -eq $false) {
        Write-Warn "allowDevTools = false  -- run -Mode EnableDevMode to enable."
    } else {
        Write-Warn "allowDevTools is not set -- run -Mode EnableDevMode to enable."
    }

    Write-Host ""
    Write-Info "Next steps:"
    if ($dt.AllowDevTools -ne $true) {
        Write-Host "  1.  .\claude-rtl.ps1 -Mode EnableDevMode"
        Write-Host "  2.  Restart Claude (close + reopen)"
        Write-Host "  3.  In Claude window: press Ctrl+Alt+I"
        Write-Host "  4.  .\claude-rtl.ps1 -Mode CopySnippet"
        Write-Host "  5.  In DevTools Console: Ctrl+V then Enter"
    } else {
        Write-Host "  1.  Open Claude (if not open) and press Ctrl+Alt+I"
        Write-Host "  2.  .\claude-rtl.ps1 -Mode CopySnippet"
        Write-Host "  3.  In DevTools Console: Ctrl+V then Enter"
    }
}

function Invoke-EnableDevModeMode {
    # Best-effort: warn if MSIX is missing but still proceed (user might
    # install Claude later; the config will be honored when it launches).
    try {
        $info = Get-ClaudeDesktopInfo
        Write-Ok "Claude Desktop v$($info.Version) detected."
    } catch {
        Write-Warn "Claude Desktop MSIX not detected ($_). Continuing with config write -- it will take effect when Claude is installed and launched."
    }

    $dt = Get-DevToolsState
    if ($dt.ConfigExists -and $dt.AllowDevTools -eq $true) {
        Write-Ok "allowDevTools is already true -- nothing to do."
        return
    }

    Set-AllowDevTools -Enable:$true
    Write-Ok "allowDevTools = true written to $ConfigPath"

    if (Get-RunningClaudeMainProcesses) {
        Write-Warn "Claude is currently running. Close and reopen it for the change to take effect."
    } else {
        Write-Info "Launch Claude. DevTools opens automatically if CLAUDE_DEV_TOOLS env var is set."
    }
}

function Invoke-DisableDevModeMode {
    $dt = Get-DevToolsState
    if (-not $dt.ConfigExists -or $null -eq $dt.AllowDevTools) {
        Write-Info "allowDevTools is not currently set -- nothing to remove."
        return
    }
    Set-AllowDevTools -Enable:$false
    Write-Ok "Key removed. Restart Claude for it to take effect."
}

function Invoke-SetupMode {
    Write-Info "=== Claude RTL Companion -- Setup ==="
    Write-Info "Step 1/3: enable allowDevTools in config.json"
    Invoke-EnableDevModeMode

    Write-Info ""
    Write-Info "Step 2/3: set CLAUDE_DEV_TOOLS=detach user env var"
    Set-ClaudeDevToolsEnv -Value 'detach'

    Write-Info ""
    Write-Info "Step 3/3: copy current RTL snippet to clipboard"
    try { Copy-SnippetToClipboard } catch { Write-Warn "Could not copy snippet: $_" }

    Write-Host ""
    Write-Ok "Setup complete. Next:"
    Write-Host "  1. Close Claude Desktop completely (also from the system tray)."
    Write-Host "  2. Reopen Claude. DevTools should auto-open in a separate window."
    Write-Host "  3. In DevTools click the Console tab, then Ctrl+V then Enter."
    Write-Host ""
    Write-Info "For a permanent one-click flow, see Option A (DevTools Snippets) in the README."
}

function Invoke-CopySnippetMode {
    Copy-SnippetToClipboard
    Write-Host ""
    Write-Info "Now do this in Claude:"
    Write-Host "  1. Make sure Claude is open and focused."
    Write-Host "  2. Press Ctrl+Alt+I to open DevTools (requires dev mode enabled)."
    Write-Host "  3. Click on the 'Console' tab."
    Write-Host "  4. Click inside the console, then press Ctrl+V to paste."
    Write-Host "  5. Press Enter to run."
    Write-Host ""
    Write-Info "Hebrew/RTL text will render correctly until you restart Claude."
    Write-Info "To undo within the same session: in Console, type  claudeRtlRemove()"
}

function Invoke-PrintSnippetMode {
    Write-Info "=== Manual DevTools snippet ==="
    Get-Snippet | Write-Host
}

function Get-ClaudeExeInfo {
    $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue
    if (-not $pkg) { throw "Claude Desktop (MSIX) not installed." }
    $app = (Get-AppxPackageManifest $pkg).Package.Applications.Application |
        Select-Object -First 1
    $exe = Join-Path $pkg.InstallLocation $app.Executable
    if (-not (Test-Path $exe)) { throw "Claude executable not found at: $exe" }
    [PSCustomObject]@{
        Exe    = $exe
        AppUmi = "shell:AppsFolder\$($pkg.PackageFamilyName)!$($app.Id)"
    }
}

function Invoke-LaunchLtrMode {
    # On Hebrew/Arabic Windows display languages, Chromium mirrors the whole
    # window (RTL frame). Claude Desktop then draws its embedded browser/
    # preview panes twice: the live webview positioned in one coordinate
    # space and a snapshot layer in the other, so a "ghost" copy floats over
    # the chat. Forcing the app's UI locale/direction to LTR sidesteps the
    # mirroring entirely. Chat content RTL is unaffected (the snippet handles
    # that inside the page). The flags are needed on EVERY launch: the app's
    # config.json "locale" key is UI language only and does not stop the
    # mirroring, so there is nothing persistent to set.
    #
    # The pinned shortcut runs this hidden, so also log to a file --
    # otherwise auto-inject failures are invisible.
    $log = Join-Path $env:TEMP 'claude-rtl-launch.log'
    try { Start-Transcript -Path $log -ErrorAction SilentlyContinue | Out-Null } catch {}
    try {
        $info = Get-ClaudeExeInfo
        $running = @(Get-RunningClaudeMainProcesses)
        if ($running.Count -gt 0) {
            # Electron's single-instance lock makes a second launch ignore CLI
            # flags -- launching again would silently do nothing. Behave like a
            # normal app icon instead: focus the existing window.
            Write-Info "Claude is already running (PID $($running[0].ProcessId)); focusing it."
            Write-Info "For the LTR window chrome to apply, quit Claude fully (tray -> Quit) and launch again."
            Start-Process explorer.exe $info.AppUmi
            return
        }

        Update-RepoQuietly
        Copy-SnippetToClipboard
        Write-Info "Launching Claude with LTR window chrome:"
        Write-Host "  `"$($info.Exe)`" --lang=en-US --force-ui-direction=ltr"
        Start-Process -FilePath $info.Exe -ArgumentList '--lang=en-US', '--force-ui-direction=ltr'
        Write-Ok "Launched. Window controls should now be on the RIGHT (unmirrored)."
        Write-Info "Snippet is on the clipboard: DevTools Console -> Ctrl+V -> Enter."
        Invoke-AutoInject
    } finally {
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
}

# The detached DevTools window title is "Developer Tools - <url>"
# (verified live on Claude Desktop 1.22209.3.0; it is NOT "DevTools").
$DevToolsTitlePattern = '*Developer Tools*'

function Find-DevToolsWindow {
    param([int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $win = Get-Process -Name 'Claude' -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -like $DevToolsTitlePattern } |
            Select-Object -First 1
        if ($win) { return $win.MainWindowTitle }
    }
    return $null
}

function Invoke-InjectMode {
    # Per-session injection. Claude's session views are native
    # WebContentsViews (verified: app.asar has 8x WebContentsView/
    # addChildView, zero <webview> tags), so shell-document JS cannot
    # reach them and Ctrl+Alt+I targets the FOCUSED webview. Flow:
    # the user clicks into their session, then triggers this mode
    # (pinned shortcut / Ctrl+Alt+R hotkey); we open DevTools for that
    # session, run the saved snippet, close DevTools, restore the
    # user's keyboard layout.
    Add-Type -Namespace ClaudeRtlI -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
[DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint thread);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
'@ -ErrorAction SilentlyContinue

    $running = @(Get-RunningClaudeMainProcesses)
    if ($running.Count -eq 0) {
        Write-Err "Claude is not running. Launch it first (Claude-RTL.cmd), open your session, then run Inject."
        exit 1
    }

    # The clipboard feeds the editor-sync step in Invoke-AutoInject (the
    # saved DevTools snippet is refreshed from the repo on every inject).
    Update-RepoQuietly
    Copy-SnippetToClipboard
    Invoke-AutoInject -Immediate

    # Restore the user's keyboard layout on the MAIN window -- the en-US
    # switch we did for the chords would otherwise silently leave them
    # typing English in the chat.
    $shell2 = New-Object -ComObject WScript.Shell
    if ($shell2.AppActivate('Claude')) {
        Start-Sleep -Milliseconds 400
        $fg = [ClaudeRtlI.Win32]::GetForegroundWindow()
        # Post the user's DEFAULT layout (first in their list) back.
        $tid = [ClaudeRtlI.Win32]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
        $cur = [ClaudeRtlI.Win32]::GetKeyboardLayout(0)  # calling thread's = user default-ish
        [void][ClaudeRtlI.Win32]::PostMessage($fg, 0x0050, [IntPtr]::Zero, $cur)
    }
}

function Invoke-AutoInject {
    param([switch]$Immediate)
    # Zero-touch injection. Prerequisite (one-time): in Claude's DevTools,
    # save the snippet as a DevTools snippet named "Claude-RTL" (Sources ->
    # Snippets -> New snippet; override the expected name with -SnippetName).
    # Flow (each step verified live):
    #   1. Wait for the main Claude window; give DevTools a chance to
    #      auto-open (CLAUDE_DEV_TOOLS=detach). If it doesn't, focus the
    #      main window and send Ctrl+Alt+I to open it ourselves.
    #   2. Focus the DevTools window and drive Quick Open:
    #      Ctrl+P, "!<name>", Enter -- the "!" prefix runs snippets.
    #      NOT Ctrl+Shift+P: the Command Menu pre-fills ">", producing
    #      ">!name" which matches nothing (bug found live).
    # SendKeys resolves every character (including the 'i'/'p' in the
    # chords) through the window's ACTIVE keyboard layout, so under a
    # Hebrew layout the keystrokes would mis-translate. Before typing into
    # any window we switch its input language to en-US via
    # WM_INPUTLANGCHANGEREQUEST -- per-window, the desktop keeps its layout.
    # Every bail-out leaves the snippet on the clipboard for manual paste.
    Add-Type -Namespace ClaudeRtl -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);
[DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern IntPtr LoadKeyboardLayout(string pwszKLID, uint Flags);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern IntPtr FindWindow(string cls, string title);
[DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, System.UIntPtr extra);
'@ -ErrorAction SilentlyContinue

    $shell = New-Object -ComObject WScript.Shell

    # Left-click at a fractional position inside the FOREGROUND window.
    # Used at launch to move focus from the shell document into the session
    # view (the transcript area) so Ctrl+Alt+I targets the session.
    function Click-InForeground([double]$FracX, [double]$FracY) {
        $fg = [ClaudeRtl.Win32]::GetForegroundWindow()
        $r = New-Object ClaudeRtl.Win32+RECT
        [void][ClaudeRtl.Win32]::GetWindowRect($fg, [ref]$r)
        $x = $r.Left + [int](($r.Right - $r.Left) * $FracX)
        $y = $r.Top + [int](($r.Bottom - $r.Top) * $FracY)
        [void][ClaudeRtl.Win32]::SetCursorPos($x, $y)
        Start-Sleep -Milliseconds 150
        [ClaudeRtl.Win32]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)   # LEFTDOWN
        [ClaudeRtl.Win32]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)   # LEFTUP
        Start-Sleep -Milliseconds 300
    }

    # Focus a window by title, verify it really is foreground, then switch
    # its input language to en-US. Returns $true when safe to type.
    # AppActivate alone loses to Windows' foreground lock when the user is
    # actively working in another app; SwitchToThisWindow is the fallback.
    function Set-TypingTarget([string]$Title, [string]$Pattern) {
        $null = $shell.AppActivate($Title)
        Start-Sleep -Milliseconds 700
        $fg = [ClaudeRtl.Win32]::GetForegroundWindow()
        $sb = New-Object System.Text.StringBuilder 512
        [void][ClaudeRtl.Win32]::GetWindowText($fg, $sb, 512)
        if ($sb.ToString() -notlike $Pattern) {
            $h = [ClaudeRtl.Win32]::FindWindow($null, $Title)
            if ($h -ne [IntPtr]::Zero) {
                [ClaudeRtl.Win32]::SwitchToThisWindow($h, $true)
                Start-Sleep -Milliseconds 700
                $fg = [ClaudeRtl.Win32]::GetForegroundWindow()
                $sb = New-Object System.Text.StringBuilder 512
                [void][ClaudeRtl.Win32]::GetWindowText($fg, $sb, 512)
            }
        }
        if ($sb.ToString() -notlike $Pattern) {
            Write-Warn "Foreground window is '$($sb.ToString())', expected '$Pattern' -- not typing."
            return $false
        }
        $hkl = [ClaudeRtl.Win32]::LoadKeyboardLayout('00000409', 1)  # KLF_ACTIVATE
        [void][ClaudeRtl.Win32]::PostMessage($fg, 0x0050, [IntPtr]::Zero, $hkl)  # WM_INPUTLANGCHANGEREQUEST
        Start-Sleep -Milliseconds 300
        return $true
    }

    # -- Step 1: get a DevTools window on screen ----------------------------
    if (-not $Immediate) {
        # Fresh launch: wait for the app's main window first.
        $mainDeadline = (Get-Date).AddSeconds(60)
        $main = $null
        while ((Get-Date) -lt $mainDeadline) {
            Start-Sleep -Milliseconds 500
            $main = Get-Process -Name 'Claude' -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowTitle -eq 'Claude' } | Select-Object -First 1
            if ($main) { break }
        }
        if (-not $main) {
            Write-Warn "Claude main window not found within 60s -- skipping auto-inject."
            return
        }
    }

    # Ctrl+Alt+I opens DevTools for the FOCUSED webview. Session views are
    # native WebContentsViews whose document URL is claude.ai/epitaxy/local_*
    # -- and one view is REUSED across all sessions (verified live), so a
    # single injection into it covers every chat until the app exits.
    # At launch the shell has focus, so we first CLICK into the transcript
    # area to focus the session view, then verify by the DevTools title
    # ('local_' = session document, otherwise we hit the shell and retry).
    # In Immediate mode (Ctrl+Alt+R) the user's own focus picks the target.
    # Acquire a DevTools window attached to the SESSION view. A window may
    # already exist (CLAUDE_DEV_TOOLS=detach auto-open fires on some
    # launches, or a leftover) -- it goes through the SAME verification as
    # one we open ourselves; a non-session target gets closed and retried.
    $title = Find-DevToolsWindow -TimeoutSec 1
    $attempt = 0
    while ($true) {
        if ($title) {
            # A freshly opened window may still be loading and titled just
            # "Developer Tools" -- let it settle and re-read, the URL suffix
            # carries the 'local_' session marker we verify against.
            if ($title -notlike '*-*') {
                Start-Sleep -Milliseconds 1500
                $settled = Find-DevToolsWindow -TimeoutSec 1
                if ($settled) { $title = $settled }
            }
            if ($Immediate -or $title -like '*local_*') { break }   # good target
            if ($attempt -ge 3) { break }   # give up -> shell as best effort
            Write-Info "DevTools attached to '$title' (not a session view); closing and retrying."
            if (Set-TypingTarget $title $DevToolsTitlePattern) { $shell.SendKeys('%{F4}') }
            Start-Sleep -Milliseconds 900
            $title = $null
        }
        $attempt++
        if (-not $Immediate) { Start-Sleep -Seconds 2 }   # let the app settle
        if (-not (Set-TypingTarget 'Claude' 'Claude*')) {
            Write-Warn "Could not safely focus the Claude window -- paste manually (snippet is on the clipboard)."
            return
        }
        if (-not $Immediate) {
            Click-InForeground 0.62 0.45   # focus the session view
        }
        $shell.SendKeys('^%i')   # Ctrl+Alt+I
        $title = Find-DevToolsWindow -TimeoutSec 15
        if (-not $title) {
            Write-Warn "No DevTools window appeared -- skipping auto-inject. Is allowDevTools enabled? (-Mode Setup)."
            return
        }
    }
    Write-Info "DevTools window: '$title'"
    if ($title -notlike '*local_*') {
        Write-Warn "This DevTools is NOT a session view (no 'local_' in the URL) -- injecting anyway, but the chat may be unaffected."
        Write-Warn "Click inside the chat area and press Ctrl+Alt+R to inject the session itself."
    }

    # -- Step 2: run the saved snippet via the Command Menu -----------------
    Start-Sleep -Seconds 2   # let DevTools finish loading its panels
    if (-not (Set-TypingTarget $title $DevToolsTitlePattern)) {
        Write-Warn "Could not safely focus the DevTools window -- paste manually (snippet is on the clipboard)."
        return
    }
    # Normalize DevTools zoom first. A chord's Ctrl can register as still
    # held when the next typed character arrives while DevTools is busy --
    # a '-' then becomes Ctrl+Minus (zoom out), and DevTools PERSISTS its
    # zoom level across sessions. Ctrl+0 both prevents confusion and heals
    # any past accident.
    $shell.SendKeys('^0')
    Start-Sleep -Milliseconds 300
    # Quick Open filter: lowercase alphanumerics only. Fuzzy matching still
    # finds the snippet ("claudertl" -> "Claude-RTL"), and dropping hyphens/
    # uppercase avoids exactly the stuck-modifier race described above.
    $filter = ($SnippetName.ToLower() -replace '[^a-z0-9]', '')
    if (-not $filter) { $filter = $SnippetName -replace '([+^%~(){}\[\]])', '{$1}' }
    $shell.SendKeys('^p')        # Quick Open (NOT ^+p -- see note above)
    Start-Sleep -Milliseconds 500
    $shell.SendKeys('!' + $filter)  # "!" is literal in WScript SendKeys (not Alt)
    Start-Sleep -Milliseconds 600
    $shell.SendKeys('{ENTER}')   # opens the snippet in the editor...
    Start-Sleep -Milliseconds 800
    # ...because on current DevTools (148) "!name"+Enter only OPENS the
    # snippet -- it does not run it (verified live with screenshots).
    # While the editor is focused, SYNC the saved snippet from the repo:
    # the clipboard holds the latest inject-snippet.js (Copy-SnippetToClipboard
    # ran at the start of both LaunchLtr and Inject), so select-all + paste +
    # save keeps the DevTools copy current -- git pull + inject = updated,
    # no manual re-pasting ever. A corrupted clipboard would momentarily
    # break the saved copy, but the next inject re-syncs it from the repo.
    $shell.SendKeys('^a')
    Start-Sleep -Milliseconds 250
    $shell.SendKeys('^v')
    Start-Sleep -Milliseconds 500
    $shell.SendKeys('^s')
    Start-Sleep -Milliseconds 500
    # Ctrl+Enter runs the snippet open in the editor. Idempotent -- a
    # double-run is harmless.
    $shell.SendKeys('^{ENTER}')
    Start-Sleep -Milliseconds 900
    # Close the DevTools window we opened -- the injected style/observers
    # live in the page and survive DevTools closing.
    $fgNow = [ClaudeRtl.Win32]::GetForegroundWindow()
    $sbNow = New-Object System.Text.StringBuilder 512
    [void][ClaudeRtl.Win32]::GetWindowText($fgNow, $sbNow, 512)
    if ($sbNow.ToString() -like $DevToolsTitlePattern) {
        $shell.SendKeys('%{F4}')
    }
    Write-Ok "Auto-inject sent: DevTools snippet '$SnippetName' should be running."
    Write-Info "One-time prerequisite if nothing happened: save the snippet in DevTools as a snippet named '$SnippetName'."
}

function Invoke-InstallShortcutMode {
    # Creates two Start Menu shortcuts with Claude's own icon:
    #   "Claude (LTR)"        -- silently runs -Mode LaunchLtr. Pin it to
    #                            the taskbar; it IS the app icon from now on.
    #   "Claude RTL Inject"   -- silently runs -Mode Inject, with global
    #                            hotkey Ctrl+Alt+R. Press it while inside a
    #                            session to inject that session's webview.
    $info = Get-ClaudeExeInfo
    $programs = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
    $shell = New-Object -ComObject WScript.Shell

    $lnkPath = Join-Path $programs 'Claude (LTR).lnk'
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = 'powershell.exe'
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Mode LaunchLtr"
    $lnk.WorkingDirectory = $scriptDir
    $lnk.IconLocation = "$($info.Exe),0"
    $lnk.WindowStyle = 7  # minimized: hides the brief console flash
    $lnk.Description = 'Claude Desktop with LTR window chrome (RTL ghost-pane workaround)'
    $lnk.Save()
    Write-Ok "Shortcut created: $lnkPath"

    $injPath = Join-Path $programs 'Claude RTL Inject.lnk'
    $inj = $shell.CreateShortcut($injPath)
    $inj.TargetPath = 'powershell.exe'
    $inj.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Mode Inject"
    $inj.WorkingDirectory = $scriptDir
    $inj.IconLocation = "$($info.Exe),0"
    $inj.WindowStyle = 7
    $inj.Hotkey = 'Ctrl+Alt+R'
    $inj.Description = 'Inject the Claude-RTL snippet into the focused Claude session (Ctrl+Alt+R)'
    $inj.Save()
    Write-Ok "Shortcut created: $injPath (hotkey: Ctrl+Alt+R)"

    Write-Info "Pin 'Claude (LTR)' to the taskbar and launch Claude through it from now on."
    Write-Info "Inside a session, press Ctrl+Alt+R (or run 'Claude RTL Inject') to RTL-fix that session."
    Write-Warn "After a Microsoft Store update the ICONS may go generic (shortcuts keep working); re-run -Mode InstallShortcut to refresh."
}

# ============================================================================
# Dispatch
# ============================================================================
switch ($Mode) {
    'Status'         { Invoke-StatusMode }
    'Setup'          { Invoke-SetupMode }
    'EnableDevMode'  { Invoke-EnableDevModeMode }
    'DisableDevMode' { Invoke-DisableDevModeMode }
    'CopySnippet'    { Invoke-CopySnippetMode }
    'PrintSnippet'   { Invoke-PrintSnippetMode }
    'LaunchLtr'      { Invoke-LaunchLtrMode }
    'InstallShortcut' { Invoke-InstallShortcutMode }
    'Inject'         { Invoke-InjectMode }
}
