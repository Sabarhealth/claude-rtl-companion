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

# Raw run marker, written before anything else can fail -- answers "did the
# hotkey/shortcut actually invoke the script at all" independently of the
# transcript machinery.
try {
    Add-Content -Path (Join-Path $env:TEMP 'claude-rtl-runs.txt') `
        -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') mode=$Mode" -ErrorAction SilentlyContinue
} catch {}

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

    # Claude 1.30096+ moved the flag to its own file, developer_settings.json
    # (config.json's allowDevTools is ignored there). Write BOTH so every
    # version is covered. Must be BOM-less: Node's JSON.parse rejects a BOM
    # and the app then silently treats dev tools as disabled.
    $devSettings = Join-Path (Split-Path -Parent $ConfigPath) 'developer_settings.json'
    if ($Enable) {
        [System.IO.File]::WriteAllText($devSettings,
            "{`n  `"allowDevTools`": true`n}",
            (New-Object System.Text.UTF8Encoding $false))
        Write-Info "developer_settings.json written (1.30096+ mechanism)."
    } elseif (Test-Path $devSettings) {
        Remove-Item -LiteralPath $devSettings -Force
        Write-Info "developer_settings.json removed."
    }
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
# ============================================================================
# CDP injection (Claude 1.30096+)
# ============================================================================
# From 1.30096 the app shell is a local Vite renderer and the chat lives in a
# WebContentsView that no accelerator or menu item can attach DevTools to, so
# the DevTools UI-automation path cannot reach it. Instead we talk to
# Electron's main-process inspector and inject into every webContents
# programmatically -- no keystrokes, no focus stealing. See
# scripts/cdp-inject.ps1 for the protocol details.
$InspectorPort = 9229   # Node/main-process inspector (Developer menu)
$RemotePort    = 9222   # Chromium DevTools Protocol (--remote-debugging-port)

function Test-InspectorPort {
    try {
        $null = Invoke-RestMethod -Uri "http://127.0.0.1:$InspectorPort/json/list" -TimeoutSec 3
        return $true
    } catch { return $false }
}


function Test-RemotePort {
    try {
        $null = Invoke-RestMethod -Uri "http://127.0.0.1:$RemotePort/json/list" -TimeoutSec 3
        return $true
    } catch { return $false }
}

function Invoke-RendererInject {
    # Preferred path: Chromium's DevTools Protocol endpoint, opened by
    # --remote-debugging-port at launch. Needs no menu, no inspector and no
    # input synthesis, and it registers the snippet for future documents too,
    # so new chats are covered without re-running anything.
    param([switch]$Quiet)
    $cdp = Join-Path $scriptDir 'scripts\cdp-renderer.ps1'
    if (-not (Test-Path $cdp)) { return $false }
    if (-not (Test-RemotePort)) { return $false }
    if ($Quiet) { & $cdp -SnippetPath $SnippetPath -Port $RemotePort -Quiet }
    else { & $cdp -SnippetPath $SnippetPath -Port $RemotePort }
    return ($LASTEXITCODE -eq 0)
}

function Invoke-CdpInject {
    # This tool NEVER synthesizes mouse clicks or keystrokes. Earlier versions
    # drove Claude's menus and DevTools with SendKeys/mouse_event; whenever the
    # foreground window was not the one we expected, those inputs leaked into
    # whatever app the user was actually working in. All of it is gone: the
    # CDP path below only speaks to Electron over a local socket, so it cannot
    # touch focus, the keyboard layout, or any other window.
    $cdp = Join-Path $scriptDir 'scripts\cdp-inject.ps1'
    if (-not (Test-Path $cdp)) { Write-Warn "cdp-inject.ps1 not found."; return $false }
    if (-not (Test-InspectorPort)) {
        Write-Warn "No injection channel is open."
        Write-Info "Normally there is nothing to do: launch Claude with the 'Claude (LTR)' shortcut and"
        Write-Info "the DevTools Protocol port is open from the start (no menus, no keystrokes)."
        Write-Info "If Claude was started some other way, either relaunch it with that shortcut, or"
        Write-Info "enable the fallback channel once: hamburger -> Developer -> Enable Main Process Debugger."
        return $false
    }
    & $cdp -SnippetPath $SnippetPath -Port $InspectorPort
    return ($LASTEXITCODE -eq 0)
}

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
    try { Start-Transcript -Path $log -Append -ErrorAction SilentlyContinue | Out-Null } catch {}
    try {
        $info = Get-ClaudeExeInfo
        $running = @(Get-RunningClaudeMainProcesses)
        if ($running.Count -gt 0) {
            if ($running[0].CommandLine -match 'force-ui-direction') {
                # Already running WITH our flags -- behave like a normal app
                # icon: focus the existing window. (Electron's single-instance
                # lock would ignore flags on a second launch anyway.)
                Write-Info "Claude is already running with LTR flags (PID $($running[0].ProcessId)); focusing it."
                Start-Process explorer.exe $info.AppUmi
                return
            }
            # Running WITHOUT the flags -- the classic post-Store-update
            # state (updates relaunch the app flagless, mirrored, ghost pane
            # and all). Clicking the LTR launcher in that state is an
            # explicit request for a correct instance: close the flagless
            # one gracefully and fall through to a fresh flagged launch.
            Write-Info "Running instance has NO LTR flags (post-update relaunch?); restarting it."
            $proc = Get-Process -Id $running[0].ProcessId -ErrorAction SilentlyContinue
            if ($proc) { $null = $proc.CloseMainWindow() }
            $dl = (Get-Date).AddSeconds(8)
            while ((Get-Date) -lt $dl -and @(Get-RunningClaudeMainProcesses).Count -gt 0) {
                Start-Sleep -Milliseconds 700
            }
            if (@(Get-RunningClaudeMainProcesses).Count -gt 0) {
                # Close button often minimizes to tray instead of quitting;
                # stop the main process (chat state is server-side, and the
                # user asked for a restart by clicking the launcher).
                Write-Info "Graceful close did not exit (tray-minimize?); stopping the process."
                Get-RunningClaudeMainProcesses | ForEach-Object {
                    try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
                }
                Start-Sleep -Seconds 2
            }
            if (@(Get-RunningClaudeMainProcesses).Count -gt 0) {
                Write-Warn "Could not close the running instance -- quit manually (tray -> Quit) and click the shortcut again."
                return
            }
            Start-Sleep -Seconds 1   # let the single-instance lock release
        }

        Update-RepoQuietly
        Copy-SnippetToClipboard
        Write-Info "Launching Claude with LTR window chrome + DevTools Protocol port:"
        Write-Host "  `"$($info.Exe)`" --lang=en-US --force-ui-direction=ltr --remote-debugging-port=$RemotePort"
        # --remote-debugging-port is what makes the whole flow hands-free: it
        # opens Chromium's CDP endpoint for every renderer at launch, so the
        # snippet can be injected (and registered for future documents)
        # without a single click or keystroke. The app does not strip it; it
        # only notes it as a "dangerous switch" and disables Claude-in-Chrome
        # local pairing for that launch -- see scripts/cdp-renderer.ps1.
        # (--inspect is NOT passed: this build ignores it, the node-cli-inspect
        # fuse is off.)
        Start-Process -FilePath $info.Exe -ArgumentList '--lang=en-US', '--force-ui-direction=ltr', "--remote-debugging-port=$RemotePort"
        Write-Ok "Launched. Window controls should now be on the RIGHT (unmirrored)."

        # Wait for the CDP endpoint, then inject into every view.
        $dl = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $dl -and -not (Test-RemotePort)) { Start-Sleep -Milliseconds 700 }
        Start-Sleep -Seconds 4   # let the session view finish loading
        if (-not (Invoke-RendererInject)) {
            [void](Invoke-CdpInject)   # older builds / flagless launch
        }
    } finally {
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
}


# Process.MainWindowTitle exposes only ONE window per process -- whichever
# Windows currently deems "main" -- so an open DevTools window can hide
# behind the focused main window and the old finder would miss it (observed
# live). Enumerate ALL visible top-level windows instead.
if (-not ('ClaudeRtl.WinEnum' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace ClaudeRtl {
  public static class WinEnum {
    delegate bool EnumProc(IntPtr h, IntPtr lp);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr h, StringBuilder t, int c);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    public static System.Collections.Generic.List<string> Titles() {
      var list = new System.Collections.Generic.List<string>();
      EnumWindows((h, lp) => {
        if (IsWindowVisible(h)) {
          var sb = new StringBuilder(512);
          GetWindowText(h, sb, 512);
          if (sb.Length > 0) list.Add(sb.ToString());
        }
        return true;
      }, IntPtr.Zero);
      return list;
    }
  }
}
'@ -ErrorAction SilentlyContinue
}

# Claude 1.26832+ wraps window titles in Unicode bidi control marks
# (U+202A "Claude" U+202C -- measured live), which silently breaks exact
# and prefix title matching. Strip them before ANY comparison; activation
# still uses the EXACT (marked) title string.
function Strip-BidiMarks([string]$s) {
    if ($null -eq $s) { return '' }
    # LRM/RLM, LRE..RLO+PDF, LRI..PDI (the .NET regex engine parses \uXXXX)
    return ($s -replace '[‎‏‪-‮⁦-⁩]', '')
}

function Find-ClaudeMainTitle {
    [ClaudeRtl.WinEnum]::Titles() |
        Where-Object { (Strip-BidiMarks $_) -eq 'Claude' } |
        Select-Object -First 1
}


function Invoke-InjectMode {
    # Per-session injection. Claude's session views are native
    # WebContentsViews (verified: app.asar has 8x WebContentsView/
    # addChildView, zero <webview> tags), so shell-document JS cannot reach
    # them. Injection goes through Electron's main-process inspector, which
    # reaches every view at once -- no focus required, so this is safe to
    # trigger from anywhere (Ctrl+Alt+R) while you work in another app.
    $log = Join-Path $env:TEMP 'claude-rtl-launch.log'
    try { Start-Transcript -Path $log -Append -ErrorAction SilentlyContinue | Out-Null } catch {}
    try {
        $running = @(Get-RunningClaudeMainProcesses)
        if ($running.Count -eq 0) {
            Write-Err "Claude is not running. Launch it first (Claude-RTL.cmd), open your session, then run Inject."
            exit 1
        }

        Update-RepoQuietly
        # Clipboard copy is a convenience for the manual Console fallback.
        Copy-SnippetToClipboard
        # Renderer CDP first (open from launch, nothing to enable), then the
        # main-process inspector for flagless launches and older builds.
        if (-not (Invoke-RendererInject)) {
            [void](Invoke-CdpInject)
        }
    } finally {
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
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
