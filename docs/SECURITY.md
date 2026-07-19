# Security model

This document explains exactly what `claude-rtl.ps1` does at the system
level and why each step is safe, in enough detail to satisfy a security
review.

## Threat model

We assume an enterprise endpoint with:

- BitLocker / Defender / a third-party EDR (CrowdStrike, SentinelOne, etc.)
- Application control / WDAC / AppLocker (typical for managed devices)
- A policy that flags **modification of signed binaries** or **persistence
  artefacts** as suspicious

The goal is to enable RTL rendering in Claude Desktop **without producing
any of the signals** that would legitimately concern such a stack.

## Approach in one sentence

Use Claude Desktop's own officially-shipped *Enable Developer Mode*
feature -- which writes `allowDevTools: true` to a user-controlled
config file -- to unlock the in-app Ctrl+Alt+I keyboard shortcut, then
paste a CSS-only snippet into the resulting DevTools Console.

## What the launcher touches

| Surface | Read | Write | Notes |
|---|---|---|---|
| `C:\Program Files\WindowsApps\Claude_*\` | path discovery only (`Get-AppxPackage`) | **no** | Read-only metadata. No file inside is opened for write. |
| `app.asar`, `app.asar.unpacked` | **no** at runtime | **no** | The Electron bundle is not opened. (We documented its public string content while designing the tool, but the script does not parse or read the asar in operation.) |
| MSIX signature / `AppxManifest.xml` | no | **no** | Signature is preserved verbatim. |
| `%APPDATA%\Claude\config.json` | yes | yes -- one key (`allowDevTools`) | The same key Claude's own *Enable Developer Mode* menu writes. We back the file up before every write. |
| `%APPDATA%\Claude\` (anything else) | no | **no** | We touch no other file in the profile. |
| Registry | no | **no** | No registry keys are created or modified. |
| Scheduled Tasks / Services / Startup | no | **no** | No autostart artefact. |
| Network | none | none | Nothing is sent or received over the network. No port is opened. |

## What the launcher writes

Exactly one of these:

```jsonc
// after EnableDevMode
{
  ...,
  "allowDevTools": true
}

// after DisableDevMode
{
  ... // allowDevTools key removed
}
```

A timestamped backup (`config.json.bak.YYYYMMDD-HHmmss`) is created
before every write.

## What `allowDevTools` does

It is a documented user-config key that gates the in-app
*Enable Developer Mode* feature. When `true`:

- The `Ctrl+Alt+I` keyboard shortcut opens DevTools.
- A *Show Dev Tools* / *Show All Dev Tools* / *Inspect Element* group of
  menu items becomes visible.
- The `claude-simulator://` and other internal protocol surfaces remain
  exactly as they are (the flag does not change app capabilities, only
  developer-tool visibility).

When `false` or absent, none of the above happens.

This is the same flag Claude's own menu writes when you click
*Enable Developer Mode*. We are not bypassing a signed control; we are
exercising one.

## What is injected into Claude

A single `<style id="claude-rtl-companion">` element whose rules are
embedded in the snippet itself as a string literal. The injected
JavaScript does the following and nothing else:

1. Removes the previous `<style id="claude-rtl-companion">` if present.
2. Creates a new `<style>` element, sets `textContent` from a string
   literal, and appends it to `document.head`.
3. Installs a `MutationObserver` on `document.documentElement` whose
   only handler reapplies steps 1+2 if the `<style>` tag is removed by
   a route change.
4. Exposes `window.claudeRtlRemove()` so the user can undo from the
   same Console.

It does not:

- Read any DOM content, message text, or input value.
- Send any network request.
- Read or write `localStorage`, `sessionStorage`, `IndexedDB`, cookies,
  or any other client-side store.
- Touch any window other than the one whose Console you pasted into.

## Why this won't trip antivirus

The patterns that legitimately trip endpoint protection are absent:

- **No process injection / DLL hooking.** Nothing is injected into a
  running process. The injection mechanism is "user pastes JS into
  DevTools" -- exactly what Chrome / Edge users do daily.
- **No modification of signed binaries.** `WindowsApps\` is not
  written to.
- **No persistence.** The launcher exits after each run. Nothing
  schedules itself.
- **No script obfuscation.** Both `claude-rtl.ps1` and the snippet are
  plain text. No base64, no `Invoke-Expression` of remote content,
  no `IEX (New-Object Net.WebClient).DownloadString…` pattern.
- **No elevation.** UAC is not invoked.
- **No P/Invoke.** Earlier prototypes used `PostMessage` for graceful
  shutdown; the current script does not.

## What you should still verify yourself

- **Read the script.** All of `claude-rtl.ps1` and
  `scripts/inject-snippet.js` is short and plain text.
- **Compare the diff on `config.json`.** Each `EnableDevMode` /
  `DisableDevMode` writes a `.bak` next to the file. Run
  `Compare-Object (Get-Content config.json.bak.*) (Get-Content config.json)`
  to confirm only the `allowDevTools` key changes.
- **Check no scheduled task was created.**
  `schtasks /query /fo LIST 2>$null | Select-String "claude-rtl"`
  should return nothing.

## Residual surface

Once `allowDevTools = true`:

- DevTools is a click away. Anyone with physical access to the
  unlocked machine can open it and see what's loaded in the Claude
  renderer at that moment, the same way they could on any web app
  with DevTools open. They could not extract anything they couldn't
  already get from the running app's UI.
- A malicious local process running as your user could in theory
  trigger DevTools in the Claude window (it's a normal keyboard
  shortcut once enabled). This is also true of any developer-mode
  setting in any IDE or browser.

If your threat model is "I don't want anyone with my user session to
ever look at DevTools in Claude," disable dev mode when you're done:

```powershell
.\claude-rtl.ps1 -Mode DisableDevMode
```

## Why we abandoned `--remote-debugging-port`

The earlier design opened a Chrome DevTools Protocol port via
`Claude.exe --remote-debugging-port=9223 --remote-debugging-address=127.0.0.1`
and injected over a localhost WebSocket. That design would have been
even tighter (no DevTools UI for anyone to use, port bound to
loopback, origin-matched), but **Electron 30+ strips that flag from
the command line before any application JS executes**
([microsoft/playwright#39008](https://github.com/microsoft/playwright/issues/39008)).

We verified on Claude 1.6608.2 (Electron 41.5.0): after launching
with the flag, the running process's command line shows no debug
port. The CDP path is therefore a dead end on this build.
