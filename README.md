# Claude RTL Companion

Safe, update-resilient RTL/Hebrew text rendering for **Claude Desktop** on
Windows that uses the application's own officially-shipped Developer Mode
feature -- not any kind of binary or `app.asar` patching.

## TL;DR (עברית)

פתרון לתצוגת RTL בעברית ב-Claude Desktop בלי לגעת בקבצי האפליקציה.
משתמש בפיצ'ר רשמי של Claude בשם Developer Mode (כותב `allowDevTools=true`
לקובץ הגדרות משתמש), ובמשתנה סביבה רשמי `CLAUDE_DEV_TOOLS=detach` שנקרא
על ידי `app.asar` ופותח DevTools אוטומטית. אחרי הגדרה חד-פעמית, בכל הפעלת
Claude מדביקים snippet קצר ב-Console כדי להפעיל RTL לסשן.
אין שינוי קוד אפליקציה, אין שבירה של חתימת MSIX, אין persistence שמסומן
ב-AV/EDR. עדכוני Microsoft Store עוברים שקופים.

## What this is, and what it isn't

**Is:** A small PowerShell script + CSS/JS snippet that:
1. Sets `allowDevTools: true` in `%APPDATA%\Claude\config.json` -- the same
   key Claude's own *Enable Developer Mode* menu item writes.
2. Sets `CLAUDE_DEV_TOOLS=detach` as a user environment variable -- a
   variable Claude's own `app.asar` reads to auto-open DevTools.
3. Provides a JS snippet you paste into the DevTools Console once per
   session to apply RTL CSS rules and tag elements with `dir` attributes.

**Isn't:** A patcher. The script does not unpack, modify, or repack
`app.asar`. It does not touch anything under
`C:\Program Files\WindowsApps\Claude_…\`. It does not break Claude's
MSIX signature.

## Why this approach

See [docs/SECURITY.md](docs/SECURITY.md) for the full threat-model
write-up. Short version: patchers that modify `app.asar` (e.g.
[shraga100/claude-desktop-rtl-patch](https://github.com/shraga100/claude-desktop-rtl-patch))
break the MSIX signature, require taking ownership of `WindowsApps`,
and need a watcher to re-apply after every Microsoft Store update.
All of those are legitimate red flags for endpoint protection. This
approach uses features Claude itself ships, exercised the same way
Claude's own UI exercises them.

## What it fixes

Out of the box, Claude Desktop ships with no Hebrew locale and a hard-coded
LTR layout. Mixed Hebrew+English text gets visibly wrong direction. This
project fixes:

- Hebrew/Arabic message text auto-aligning per paragraph
- Mixed-language paragraphs flowing correctly (Hebrew RTL with English
  chunks rendering left-to-right within the line)
- List bullets and numbers on the correct side of items
- Numbered lists (`1.`, `2.`, `3.`) sitting on the inline-start of RTL items
- Tables keeping source-order columns (Hebrew-only cells right-aligning,
  English-only cells left-aligning)
- Code blocks staying LTR
- The chat composer auto-flipping direction when you start typing
- Title-bar buttons not overlapping the menu button on Windows 11 RTL
  locales (via the Window Controls Overlay API)

## Requirements

- Windows 10/11
- Claude Desktop installed from Microsoft Store (MSIX). Verify with
  `Get-AppxPackage -Name Claude`.
- PowerShell 5.1 (built in) or PowerShell 7+. Both work.
- Git, if you're cloning. Otherwise you can download the repo as a ZIP.
- No admin rights needed.
- No Node / npm / external tooling required.

## Install

```powershell
# Clone anywhere you like. C:\dev\RTL is the path the docs assume.
git clone https://github.com/Sabarhealth/claude-rtl-companion.git C:\dev\RTL
cd C:\dev\RTL
```

## One-time setup

The simplest, fully non-interactive command does everything in one shot.
Safe to run repeatedly (idempotent) and safe for automated installs
including from within Claude Code itself:

```powershell
.\claude-rtl.ps1 -Mode Setup
```

This:
1. Writes `allowDevTools: true` into `%APPDATA%\Claude\config.json`
   (creates the file if Claude has never launched on this profile;
   makes a timestamped backup if it exists).
2. Sets `CLAUDE_DEV_TOOLS=detach` as a user environment variable and
   broadcasts `WM_SETTINGCHANGE` so Explorer picks it up immediately
   (no logout required).
3. Copies the latest injection snippet to your clipboard.

Then close Claude completely (including the system tray) and reopen.
DevTools should auto-open in a separate Chromium window each time Claude
starts.

On a Hebrew/Arabic Windows display language, also run once:

```powershell
.\claude-rtl.ps1 -Mode InstallShortcut
```

then pin the new **"Claude (LTR)"** Start Menu entry to your taskbar and
launch Claude through it from then on. It starts Claude with an
unmirrored (LTR) window frame, avoiding the ghost preview-pane bug
(see Troubleshooting), and puts the snippet on your clipboard on every
launch.

### If you'd rather do the steps individually

```powershell
.\claude-rtl.ps1                     # Status (read-only)
.\claude-rtl.ps1 -Mode EnableDevMode # writes config.json
.\claude-rtl.ps1 -Mode CopySnippet   # snippet -> clipboard
# Env var (Setup mode does this for you):
[Environment]::SetEnvironmentVariable("CLAUDE_DEV_TOOLS", "detach", "User")
```

### PowerShell execution policy

If `.\claude-rtl.ps1` errors with *"running scripts is disabled on this
system"*, you have two options:

```powershell
# Option 1 -- bypass once for the current process only (safest):
powershell -ExecutionPolicy Bypass -File .\claude-rtl.ps1 -Mode Setup

# Option 2 -- allow local scripts for your user (persistent):
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

## Per-session workflow

The injected CSS lives in the renderer process. When Claude is closed
the page is gone, and the next launch needs the snippet run again.
**There is no way to avoid this without modifying `app.asar`** -- and
that's exactly what we're not doing. The closest thing is Option A,
which automates the re-run completely.

### Option A -- Zero-touch (recommended)

One-time setup: save the snippet as a DevTools snippet named
**`Claude-RTL`** (the historical default -- if you already have it from
Option B, there is nothing to do):

1. Run `.\claude-rtl.ps1 -Mode CopySnippet` (puts the snippet on your
   clipboard).
2. In Claude's DevTools: **Sources** tab → left sidebar **>>** →
   **Snippets** → right-click → **New snippet**. Name it `Claude-RTL`.
3. Click into the editor, `Ctrl+V`, then `Ctrl+S` to save.
4. Run `.\claude-rtl.ps1 -Mode InstallShortcut` and pin the new
   **"Claude (LTR)"** Start Menu entry to your taskbar.

From then on, launching Claude via that pinned icon does everything:
LTR window chrome, waits for DevTools to auto-open, and runs the
`Claude-RTL` snippet through the DevTools Command Menu
(`Ctrl+Shift+P` → `!Claude-RTL` → `Enter`) -- no typing, no pasting.
Saved the snippet under a different name? Pass it:
`.\claude-rtl.ps1 -Mode LaunchLtr -SnippetName MyName` (and re-run
`InstallShortcut` after editing the shortcut arguments accordingly).

Keyboard-layout note: synthetic keystrokes normally translate through
the active layout (a Hebrew layout would garble both the
`Ctrl+Shift+P` chord and the name), so before typing, the launcher
switches the DevTools window's input language to en-US via
`WM_INPUTLANGCHANGEREQUEST`. Input language is per-window -- the rest
of your desktop keeps its layout. The DevTools snippet itself persists
across Claude restarts and Microsoft Store updates.

If auto-inject can't run (DevTools window missing, focus stolen), the
launcher warns and leaves the snippet on your clipboard -- fall back to
Option C for that session.

### Option B -- DevTools Snippets, manual trigger (3 keystrokes per session)

Same one-time setup as Option A steps 1-3. Per-session: in DevTools,
press **`Ctrl+P`**, type `!Claude-RTL`, press `Enter`.

### Option C -- Manual paste each session

Run `.\claude-rtl.ps1 -Mode CopySnippet` whenever you launch Claude,
then `Ctrl+V` and `Enter` in the DevTools Console.

`Claude-RTL.cmd` in the repo root is a double-clickable wrapper for the
Option A launch path (it delegates to `-Mode LaunchLtr`).

## Modes

| Mode | What it does |
|---|---|
| `Status` (default) | Read-only. Shows version, run state, current `allowDevTools` value. |
| `Setup` | One-shot: `EnableDevMode` + sets `CLAUDE_DEV_TOOLS=detach` env var + broadcasts the env change + copies snippet to clipboard. |
| `EnableDevMode` | Creates or updates `config.json`, sets `allowDevTools = true`. Auto-creates the file/directory if Claude has never launched. Backs up first if it exists. |
| `DisableDevMode` | Backs up `config.json`, removes the `allowDevTools` key. |
| `CopySnippet` | Puts the injection snippet on your clipboard. |
| `PrintSnippet` | Prints the snippet to stdout. |
| `LaunchLtr` | Copies the snippet, launches Claude with `--lang=en-US --force-ui-direction=ltr` (unmirrored window chrome on Hebrew/Arabic Windows display languages -- works around the ghost preview-pane layer, see Troubleshooting), then **auto-injects**: waits up to 45s for the detached DevTools window, switches its input language to en-US, and runs the DevTools snippet named `Claude-RTL` (override with `-SnippetName`) via the Command Menu. If Claude is already open it just focuses the window (Electron's single-instance lock would ignore the flags anyway). The flags are needed on every launch -- there is no persistent setting: the app's `config.json` `locale` key is UI language only and Windows has no per-app locale override for desktop apps. |
| `InstallShortcut` | Creates a Start Menu shortcut **"Claude (LTR)"** (with Claude's own icon) that silently runs `LaunchLtr`. Pin it to the taskbar and launch Claude through it from then on -- no console, no command. Re-run after a Store update if the icon goes generic. |

All modes are non-interactive (no Y/N prompts). The `-NoConfirm` flag is
accepted for backwards compatibility but is now a no-op.

## How it works (one paragraph)

The snippet adds one `<style id="claude-rtl-companion">` tag to the document
and tags certain elements with HTML `dir` attributes. CSS uses `:dir(rtl)`
to flip Tailwind Typography's absolutely-positioned list markers from
`left: 0` to `right: 0` for items inside RTL lists. The bidi algorithm
handles mixed Hebrew+English within paragraphs naturally. A debounced
`MutationObserver` (200ms) re-tags freshly-rendered content for things
like AskUserQuestion pickers and streaming assistant messages, with a
5-second `setInterval` as a safety net.

## After a Microsoft Store update

Nothing to do for `allowDevTools` (it's in your roaming profile,
untouched by Store updates). Nothing to do for the env var (also user-
scope). The DevTools Snippet you saved in Option A persists across
updates as well -- it's stored in DevTools' own profile.

The only thing that goes away on every Claude restart is the in-page
CSS injection itself. That's per-session, by design, and unavoidable
without modifying the app.

## Uninstall

```powershell
.\claude-rtl.ps1 -Mode DisableDevMode
[Environment]::SetEnvironmentVariable("CLAUDE_DEV_TOOLS", $null, "User")
```

After Claude restarts, dev mode is off, DevTools no longer auto-opens,
and there is no residual change anywhere on your system. Delete the
checkout directory and the DevTools Snippet (Sources → Snippets →
right-click → Remove) to fully clean up.

## Files

```
claude-rtl-companion/
├── claude-rtl.ps1               main launcher (PowerShell)
├── Claude-RTL.cmd               one-click per-session helper
├── scripts/
│   └── inject-snippet.js        the snippet that goes into DevTools
│                                (embeds its own CSS)
├── test/
│   └── simulation.html          31-assertion harness mimicking Claude's DOM
├── docs/
│   └── SECURITY.md              threat-model write-up
├── CHANGELOG.md
└── README.md
```

## Testing

`test/simulation.html` replicates Claude Desktop's rendering quirks
(Tailwind-prose absolute list markers, Claude-shipped `dir="ltr"`
attributes, epitaxy cards/user bubbles/codeblocks, streaming mutations)
and runs 31 assertions against the real `scripts/inject-snippet.js`. Serve the
repo root over HTTP and open the page -- results render in-page and in
`window.__rtlResults`:

```
python -m http.server 8123
# then open http://localhost:8123/test/simulation.html
```

Don't open it via `file://` -- browsers/panes may snapshot the script
and you'll test a stale version. Run this before bumping any snippet
version.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Script hangs at "Type Y to proceed" | Older version with `Read-Host` prompt running in a non-interactive shell (e.g. inside Claude Code) | Pull the latest -- prompts have been removed. Or pass `-Mode Setup` which is always non-interactive |
| `Config not found at … launch Claude at least once first` | Older version that required pre-existing `config.json` | Pull the latest -- `EnableDevMode` now creates the file if missing |
| `running scripts is disabled on this system` | PowerShell execution policy | Run with `powershell -ExecutionPolicy Bypass -File .\claude-rtl.ps1 -Mode Setup` or change policy (see *PowerShell execution policy* above) |
| DevTools doesn't auto-open | `CLAUDE_DEV_TOOLS` env var didn't propagate to Explorer | `-Mode Setup` broadcasts `WM_SETTINGCHANGE` to fix this. If still missing: sign out + back in, or open Claude via `Claude-RTL.cmd` which inherits the env var from PowerShell |
| `Ctrl+Alt+I` does nothing in Claude | Hebrew keyboard layout intercepts `Ctrl+Alt` as `AltGr` | Switch to English layout (`Win+Space`) before pressing, or rely on the auto-open env var instead |
| Hamburger menu hidden behind window-controls overlay | Windows RTL OS locale flips title-bar buttons | The snippet adds inline-start padding via the WCO API; falls back to 140px if WCO API is unavailable. Or launch via `-Mode LaunchLtr`, which unmirrors the window entirely |
| Browser/preview pane draws a duplicate "ghost" copy floating over the chat; disappears on focus, returns on blur | Claude Desktop bug on RTL-mirrored Windows (Hebrew/Arabic display language): the embedded webview and its snapshot layer are positioned in different coordinate spaces. Reproduces with no snippet injected | Quit Claude fully, relaunch via `Claude-RTL.cmd` or `-Mode LaunchLtr` (forces LTR window chrome). Chat content RTL is unaffected -- the snippet handles that inside the page |
| Snippet runs but no visual change | An older version is loaded -- clear with `claudeRtlRemove()` then re-paste current snippet |
| Lists with mixed-language items split visually (marker right, content drifting left) | Older snippet (≤ v10) -- pull latest and re-copy |
| Chat composer doesn't flip direction when typing Hebrew | Older snippet (≤ v11) without input coverage -- pull latest and re-copy |
| `Set-Clipboard` not found in PowerShell | Very old PowerShell -- use `-Mode PrintSnippet` and copy by hand |

## Contributing

Bug reports and PRs welcome. If you find a Claude Desktop UI element
that isn't handled (lists with weird structures, custom pickers,
embedded webviews), open an issue with a screenshot and the output of
the diagnostic snippet from CHANGELOG.md's v6/v7 sections.

## License

MIT.
