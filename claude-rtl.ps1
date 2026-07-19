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
    [ValidateSet('Status','Setup','EnableDevMode','DisableDevMode','CopySnippet','PrintSnippet')]
    [string]$Mode = 'Status',

    # Backwards-compat: no-op. Prompts have been removed; the script always
    # proceeds because EnableDevMode/DisableDevMode are reversible, create
    # timestamped backups, and the user already consented by specifying the
    # mode explicitly.
    [switch]$NoConfirm,

    [string]$SnippetPath
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
}
