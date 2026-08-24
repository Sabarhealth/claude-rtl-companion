<#
.SYNOPSIS
    Inject the RTL snippet into every Claude renderer via Chromium's DevTools
    Protocol endpoint (--remote-debugging-port). No UI automation whatsoever.

.DESCRIPTION
    Claude is launched with --remote-debugging-port=<Port> (see claude-rtl.ps1
    -Mode LaunchLtr). That exposes a plain HTTP/WebSocket CDP endpoint listing
    every page target -- the shell, each Claude Code session view and each
    preview pane. We connect to each and evaluate the snippet.

    Two things make this "set once and forget":
      * Runtime.evaluate applies the fix to what is already on screen.
      * Page.addScriptToEvaluateOnNewDocument registers the snippet so it is
        applied automatically to every FUTURE document in that target
        (navigations, newly opened chats) with no further action.

    -Watch keeps polling for targets that appear later (a new session view,
    a preview pane that opens minutes afterwards) and injects those too.

    Trade-off worth knowing: the app treats --remote-debugging-port as a
    "dangerous switch" and disables Claude-in-Chrome local pairing for that
    launch (log line: "[Chrome Extension MCP] local pairing disabled for this
    launch"). Nothing else is affected. If you rely on the Chrome extension,
    launch without the flag and use the main-process inspector path instead.

.PARAMETER Port
    Chromium remote-debugging port (default 9222).

.PARAMETER Watch
    Keep running, injecting into new targets as they appear.

.PARAMETER IntervalSec
    Poll interval for -Watch (default 5).
#>
[CmdletBinding()]
param(
    [string]$SnippetPath,
    [int]$Port = 9222,
    [switch]$Watch,
    [int]$IntervalSec = 5,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
if (-not $SnippetPath) { $SnippetPath = Join-Path $scriptDir 'inject-snippet.js' }

function Write-Info { param($Msg) if (-not $Quiet) { Write-Host "[cdp-renderer] $Msg" -ForegroundColor Cyan } }
function Write-Ok   { param($Msg) if (-not $Quiet) { Write-Host "[cdp-renderer] $Msg" -ForegroundColor Green } }
function Write-Err  { param($Msg) Write-Host "[cdp-renderer] $Msg" -ForegroundColor Red }

if (-not (Test-Path $SnippetPath)) { Write-Err "Snippet not found: $SnippetPath"; exit 1 }
# ReadAllText + ConvertTo-Json -InputObject: Get-Content decorates its string
# with PS note-properties, and ConvertTo-Json would then serialize the whole
# object instead of a JSON string literal.
$snippet = [System.IO.File]::ReadAllText($SnippetPath, [System.Text.Encoding]::UTF8)

function Get-CdpTargets {
    param([int]$Port)
    try {
        $all = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 5
    } catch { return $null }
    # Real content only: skip devtools frontends and empty shims.
    @($all | Where-Object {
        $_.webSocketDebuggerUrl -and
        $_.type -in @('page', 'webview') -and
        $_.url -notlike 'devtools://*' -and
        $_.url -ne 'about:blank'
    })
}

function Invoke-CdpOnTarget {
    param([string]$WsUrl, [string]$Source)
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $cts = New-Object System.Threading.CancellationTokenSource
    $result = 'no-result'
    try {
        $null = $ws.ConnectAsync([Uri]$WsUrl, $cts.Token).GetAwaiter().GetResult()

        $id = 0
        function Send-Cmd {
            param($Method, $Params)
            $script:cdpMsgId = ++$id
            $msg = @{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Depth 10 -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
            $seg = New-Object System.ArraySegment[byte] -ArgumentList @(, $bytes)
            $null = $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()
            $deadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $deadline) {
                $sb = New-Object System.Text.StringBuilder
                do {
                    $buf = New-Object byte[] 65536
                    $rseg = New-Object System.ArraySegment[byte] -ArgumentList @(, $buf)
                    $res = $ws.ReceiveAsync($rseg, $cts.Token).GetAwaiter().GetResult()
                    [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count))
                } while (-not $res.EndOfMessage)
                $obj = $sb.ToString() | ConvertFrom-Json
                if ($obj.id -eq $id) { return $obj }
            }
            throw "CDP timeout on $Method"
        }

        # Apply to the live document...
        $r = Send-Cmd 'Runtime.evaluate' @{ expression = $Source; returnByValue = $true; allowUnsafeEvalBlockedByCSP = $true }
        if ($r.result.exceptionDetails) {
            $result = 'ERR: ' + $r.result.exceptionDetails.exception.description
        } else {
            $result = [string]$r.result.result.value
        }
        # ...and register it for every future document in this target, so new
        # chats and navigations are covered without re-running anything.
        try { $null = Send-Cmd 'Page.addScriptToEvaluateOnNewDocument' @{ source = $Source } } catch {}
    } catch {
        $result = 'ERR: ' + $_.Exception.Message
    } finally {
        try { $null = $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $cts.Token).GetAwaiter().GetResult() } catch {}
        $ws.Dispose()
    }
    return $result
}

function Invoke-Sweep {
    param([hashtable]$Seen)
    $targets = Get-CdpTargets -Port $Port
    if ($null -eq $targets) { return -1 }   # endpoint not up
    $n = 0
    foreach ($t in $targets) {
        if ($Seen.ContainsKey($t.id)) { continue }
        $r = Invoke-CdpOnTarget -WsUrl $t.webSocketDebuggerUrl -Source $snippet
        $short = if ($t.url.Length -gt 70) { $t.url.Substring(0, 70) } else { $t.url }
        if ($r -like 'ERR:*') { Write-Info "  $short -> $r" }
        else { Write-Ok "  $short -> $r"; $Seen[$t.id] = $true; $n++ }
    }
    return $n
}

$seen = @{}
if (-not $Watch) {
    $n = Invoke-Sweep -Seen $seen
    if ($n -lt 0) {
        Write-Err "No CDP endpoint on 127.0.0.1:$Port."
        Write-Info "Launch Claude via 'Claude (LTR)' (claude-rtl.ps1 -Mode LaunchLtr), which passes --remote-debugging-port=$Port."
        exit 1
    }
    Write-Ok "Injected into $n target(s)."
    exit 0
}

Write-Info "Watching 127.0.0.1:$Port every ${IntervalSec}s; new views are injected automatically. Ctrl+C to stop."
while ($true) {
    $n = Invoke-Sweep -Seen $seen
    if ($n -lt 0) {
        # Endpoint gone (Claude closed): forget targets so a relaunch is picked up.
        if ($seen.Count) { Write-Info "Endpoint gone; waiting for Claude." }
        $seen = @{}
    }
    Start-Sleep -Seconds $IntervalSec
}
