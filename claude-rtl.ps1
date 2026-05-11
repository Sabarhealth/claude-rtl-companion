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
    EnableDevMode  -- set allowDevTools=true in config.json (with confirmation).
    DisableDevMode -- remove allowDevTools from config.json.
    CopySnippet    -- copy injection snippet to clipboard + show paste steps.
    PrintSnippet   -- print the snippet to stdout.

.EXAMPLE
    .\claude-rtl.ps1
    Show current state.

.EXAMPLE
    .\claude-rtl.ps1 -Mode EnableDevMode
    Enable allowDevTools in config.json, then close Claude so the next launch
    picks it up. After Claude restarts, press Ctrl+Alt+I to open DevTools.

.EXAMPLE
    .\claude-rtl.ps1 -Mode CopySnippet
    Copy snippet to clipboard. Switch to Claude DevTools Console, Ctrl+V, Enter.
#>

[CmdletBinding()]
param(
    [ValidateSet('Status','EnableDevMode','DisableDevMode','CopySnippet','PrintSnippet')]
    [string]$Mode = 'Status',

    [switch]$NoConfirm,

    [string]$CssPath,
    [string]$SnippetPath
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
if (-not $CssPath)     { $CssPath     = Join-Path $scriptDir 'styles\rtl.css' }
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

    if (-not (Test-Path $ConfigPath)) {
        throw "Config not found at $ConfigPath -- launch Claude at least once first."
    }

    # Read as ordered hashtable to preserve key order on round-trip
    $rawJson = Get-Content $ConfigPath -Raw -Encoding UTF8
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $cfg = $rawJson | ConvertFrom-Json -AsHashtable -Depth 32
    } else {
        # PS 5.1 has no -AsHashtable; convert manually preserving order
        $obj = $rawJson | ConvertFrom-Json
        $cfg = [ordered]@{}
        foreach ($p in $obj.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    }

    # Backup before write
    $backup = "$ConfigPath.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $ConfigPath -Destination $backup -Force
    Write-Info "Backup written: $backup"

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
    $info = Get-ClaudeDesktopInfo
    $dt   = Get-DevToolsState

    if (-not $dt.ConfigExists) {
        Write-Err "config.json not found at $ConfigPath. Launch Claude once first, then re-run."
        return
    }
    if ($dt.AllowDevTools -eq $true) {
        Write-Ok "allowDevTools is already true -- nothing to do."
        return
    }

    Write-Info "About to set 'allowDevTools' = true in:"
    Write-Info "  $ConfigPath"
    Write-Info "This is the same key Claude's own 'Enable Developer Mode' menu writes."
    if (-not $NoConfirm) {
        Write-Host "  Type Y to proceed, anything else to cancel." -ForegroundColor Yellow
        $ans = Read-Host
        if ($ans -notmatch '^[yY]') { Write-Info "Cancelled."; return }
    }

    Set-AllowDevTools -Enable:$true
    Write-Ok "allowDevTools = true written to config.json."

    if (Get-RunningClaudeMainProcesses) {
        Write-Warn "Claude is currently running. Close and reopen it for the change to take effect."
    } else {
        Write-Info "Now launch Claude. Press Ctrl+Alt+I once it's open."
    }
}

function Invoke-DisableDevModeMode {
    $dt = Get-DevToolsState
    if (-not $dt.ConfigExists -or $null -eq $dt.AllowDevTools) {
        Write-Info "allowDevTools is not currently set -- nothing to remove."
        return
    }
    if (-not $NoConfirm) {
        Write-Host "Remove 'allowDevTools' key from $ConfigPath ? (Y/n)" -ForegroundColor Yellow
        $ans = Read-Host
        if ($ans -notmatch '^[yY]') { Write-Info "Cancelled."; return }
    }
    Set-AllowDevTools -Enable:$false
    Write-Ok "Key removed. Restart Claude for it to take effect."
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
    'EnableDevMode'  { Invoke-EnableDevModeMode }
    'DisableDevMode' { Invoke-DisableDevModeMode }
    'CopySnippet'    { Invoke-CopySnippetMode }
    'PrintSnippet'   { Invoke-PrintSnippetMode }
}
