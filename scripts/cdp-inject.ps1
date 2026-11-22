<#
.SYNOPSIS
    Inject the RTL snippet through Electron's main-process inspector (CDP).

.DESCRIPTION
    Claude Desktop 1.30096 rebuilt the shell as a local Vite renderer and the
    chat content lives in a separate WebContentsView that no menu item and no
    accelerator can attach DevTools to. The app does, however, ship
    "Enable Main Process Debugger" (Developer menu), which opens Node's
    inspector on 127.0.0.1:9229. From there we can talk to the main process
    directly and call webContents.executeJavaScript() on EVERY view -- no UI
    automation, no focus stealing, no keystrokes. This is both simpler and far
    more resilient than driving the DevTools UI.

    Requires the debugger to be enabled once per app run:
        hamburger -> Developer -> Enable Main Process Debugger

.PARAMETER SnippetPath
    Path to inject-snippet.js (defaults to ../scripts/inject-snippet.js).

.PARAMETER Port
    Inspector port (default 9229).

.PARAMETER ListOnly
    Only list the app's webContents (id, type, url) and exit.
#>
[CmdletBinding()]
param(
    [string]$SnippetPath,
    [int]$Port = 9229,
    [switch]$ListOnly,

    # Evaluate an arbitrary expression in the MAIN process and print the
    # result. Debugging aid for probing Electron APIs across versions.
    # Use -EvalFile for multi-line expressions (avoids shell quoting).
    [string]$Eval,
    [string]$EvalFile
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
if (-not $SnippetPath) { $SnippetPath = Join-Path $scriptDir 'inject-snippet.js' }

function Write-Info { param($Msg) Write-Host "[cdp-inject] $Msg" -ForegroundColor Cyan }
function Write-Ok   { param($Msg) Write-Host "[cdp-inject] $Msg" -ForegroundColor Green }
function Write-Err  { param($Msg) Write-Host "[cdp-inject] $Msg" -ForegroundColor Red }

# --------------------------------------------------------------------------
# Locate the main-process inspector target
# --------------------------------------------------------------------------
try {
    $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 5
} catch {
    Write-Err "No inspector on 127.0.0.1:$Port."
    Write-Info "Enable it once per app run: hamburger menu -> Developer -> Enable Main Process Debugger."
    exit 1
}
$wsUrl = ($targets | Select-Object -First 1).webSocketDebuggerUrl
if (-not $wsUrl) { Write-Err "Inspector target has no webSocketDebuggerUrl."; exit 1 }

# --------------------------------------------------------------------------
# Minimal CDP client over WebSocket
# --------------------------------------------------------------------------
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$cts = New-Object System.Threading.CancellationTokenSource
$null = $ws.ConnectAsync([Uri]$wsUrl, $cts.Token).GetAwaiter().GetResult()

$script:cdpId = 0
function Invoke-Cdp {
    param([string]$Expression)
    $script:cdpId++
    $msg = @{
        id     = $script:cdpId
        method = 'Runtime.evaluate'
        params = @{
            expression    = $Expression
            returnByValue = $true
            awaitPromise  = $true
            includeCommandLineAPI = $false
        }
    } | ConvertTo-Json -Depth 10 -Compress

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)
    $null = $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()

    # Read until we see our id (inspector also emits unsolicited events).
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $sb = New-Object System.Text.StringBuilder
        do {
            $buf = New-Object byte[] 65536
            $rseg = New-Object System.ArraySegment[byte] -ArgumentList @(,$buf)
            $res = $ws.ReceiveAsync($rseg, $cts.Token).GetAwaiter().GetResult()
            [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count))
        } while (-not $res.EndOfMessage)

        $obj = $sb.ToString() | ConvertFrom-Json
        if ($obj.id -eq $script:cdpId) {
            if ($obj.error) { throw "CDP error: $($obj.error.message)" }
            if ($obj.result.exceptionDetails) {
                throw "JS exception: $($obj.result.exceptionDetails.exception.description)"
            }
            return $obj.result.result.value
        }
    }
    throw "CDP timeout waiting for response id $($script:cdpId)"
}

# `require` is not exposed in the inspector's default context; reach the app's
# module system through the main module instead.
$req = "process.mainModule.require('electron')"

try {
    if ($EvalFile) { $Eval = Get-Content $EvalFile -Raw -Encoding UTF8 }
    if ($Eval) {
        $out = Invoke-Cdp $Eval
        Write-Host $out
        exit 0
    }

    # ---------------------------------------------------------------------
    # Enumerate webContents
    # ---------------------------------------------------------------------
    $listExpr = @"
JSON.stringify($req.webContents.getAllWebContents().map(w => ({
  id: w.id, type: w.getType(), url: (w.getURL()||'').slice(0, 120),
  destroyed: w.isDestroyed()
})))
"@
    $list = (Invoke-Cdp $listExpr) | ConvertFrom-Json
    Write-Info "webContents found: $($list.Count)"
    foreach ($wc in $list) { Write-Host ("  [{0}] {1,-10} {2}" -f $wc.id, $wc.type, $wc.url) }

    if ($ListOnly) { exit 0 }

    # ---------------------------------------------------------------------
    # Inject into every non-devtools, non-destroyed view.
    # The snippet is idempotent, so injecting broadly is safe and covers the
    # shell, the content view, and any future extra views automatically.
    # ---------------------------------------------------------------------
    if (-not (Test-Path $SnippetPath)) { Write-Err "Snippet not found: $SnippetPath"; exit 1 }
    # ReadAllText, NOT Get-Content: Get-Content decorates its output string
    # with PS note-properties, and ConvertTo-Json then serializes the whole
    # decorated object ({"value":"...","Home":...}) instead of a JSON string
    # literal -- which the debugger rejects as "Invalid parameters".
    $snippet = [System.IO.File]::ReadAllText($SnippetPath, [System.Text.Encoding]::UTF8)
    # Ship the source as a JS string literal via JSON encoding, then eval it
    # inside each renderer.
    $snippetJson = ConvertTo-Json -InputObject $snippet -Compress

    # ---------------------------------------------------------------------
    # Persistent hook: inject every view that appears LATER, by itself.
    #
    # Injecting the views that exist right now covers only this moment. Claude
    # opens new WebContentsViews constantly -- a session in its own window, a
    # new chat, an incognito chat, a preview pane -- and each arrives after the
    # run that injected the others, which is why new windows looked untouched.
    #
    # Installing an app-level 'web-contents-created' listener in the MAIN
    # process fixes that class of problem rather than one instance of it: the
    # listener lives as long as Claude does, so every view created from here
    # on is injected on its own dom-ready, with nothing to re-run. dom-ready
    # also fires again after a navigation, so a view that reloads is re-covered.
    # ---------------------------------------------------------------------
    $hookExpr = @"
(() => {
  const e = $req;
  globalThis.__rtlSource = $snippetJson;

  const run = async wc => {
    if (!wc || wc.isDestroyed()) return;
    const url = wc.getURL() || '';
    if (url.startsWith('devtools://')) return;
    let attached = false;
    try { wc.debugger.attach('1.3'); attached = true; }
    catch (err) { if (!wc.debugger.isAttached()) return; }
    try {
      await wc.debugger.sendCommand('Runtime.evaluate', {
        expression: globalThis.__rtlSource,
        returnByValue: true,
        allowUnsafeEvalBlockedByCSP: true,
      });
    } catch (err) { /* a view that went away mid-flight is not an error */ }
    if (attached) { try { wc.debugger.detach(); } catch (_) {} }
  };

  // Bind a view once; dom-ready repeats per navigation, which is what we want.
  const bind = wc => {
    if (!wc || wc.__rtlBound) return;
    wc.__rtlBound = true;
    wc.on('dom-ready', () => run(wc));
  };

  for (const wc of e.webContents.getAllWebContents()) bind(wc);

  if (!globalThis.__rtlHooked) {
    globalThis.__rtlHooked = true;
    e.app.on('web-contents-created', (_ev, wc) => bind(wc));
  }
  return 'ok';
})()
"@
    try {
        $null = Invoke-Cdp $hookExpr
        Write-Ok "Future views will be injected automatically (new windows, chats, previews)."
    } catch {
        Write-Info "Could not install the auto-inject hook: $($_.Exception.Message)"
        Write-Info "Views open right now are still injected below; new ones will need another run."
    }

    # Only real content views: skip devtools, about:blank and data: shims.
    $targetsToInject = $list | Where-Object {
        -not $_.destroyed -and $_.type -ne 'remote' -and
        $_.url -notlike 'devtools://*' -and $_.url -ne 'about:blank' -and
        $_.url -notlike 'data:*'
    }
    $okCount = 0
    foreach ($wc in $targetsToInject) {
        # webContents.executeJavaScript() is subject to the renderer's CSP and
        # fails on Claude's sandboxed views ("Script failed to execute").
        # webContents.debugger + Runtime.evaluate is the same channel the
        # DevTools console uses, so it is NOT CSP-restricted. Fall back to
        # executeJavaScript only if the debugger cannot attach (e.g. DevTools
        # is already open on that view).
        $injectExpr = @"
(async () => {
  const wc = $req.webContents.fromId($($wc.id));
  if (!wc || wc.isDestroyed()) return 'gone';
  let attached = false;
  try {
    try { wc.debugger.attach('1.3'); attached = true; }
    catch (e) { if (!wc.debugger.isAttached()) throw e; }
    // Keep the parameter set minimal -- Electron's debugger rejects some
    // optional CDP fields with "Invalid parameters".
    // allowUnsafeEvalBlockedByCSP is what lets this bypass the renderer CSP
    // that blocks webContents.executeJavaScript().
    const r = await wc.debugger.sendCommand('Runtime.evaluate', {
      expression: $snippetJson, returnByValue: true, allowUnsafeEvalBlockedByCSP: true
    });
    if (r && r.exceptionDetails) return 'ERR: ' + (r.exceptionDetails.exception && r.exceptionDetails.exception.description || 'exception');
    return String((r && r.result && r.result.value) ?? 'ok');
  } catch (e) {
    try {
      const r2 = await wc.executeJavaScript($snippetJson, true);
      return String(r2) + ' (via executeJavaScript)';
    } catch (e2) { return 'ERR: ' + e.message; }
  } finally {
    if (attached) { try { wc.debugger.detach(); } catch (_) {} }
  }
})()
"@
        try {
            $r = Invoke-Cdp $injectExpr
            if ($r -like 'ERR:*' -or $r -eq 'gone') {
                Write-Info ("  [{0}] {1}" -f $wc.id, $r)
            } else {
                Write-Ok ("  [{0}] {1}" -f $wc.id, $r)
                $okCount++
            }
        } catch {
            Write-Info ("  [{0}] failed: {1}" -f $wc.id, $_.Exception.Message)
        }
    }
    Write-Ok "Injected into $okCount view(s)."
} finally {
    try { $null = $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $cts.Token).GetAwaiter().GetResult() } catch {}
    $ws.Dispose()
}
