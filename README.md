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

```powershell
# 1. Check current state (no changes made)
.\claude-rtl.ps1

# 2. Write allowDevTools=true into your Claude config (a timestamped
#    backup of config.json is made first). Asks for Y/N confirmation.
.\claude-rtl.ps1 -Mode EnableDevMode

# 3. Set CLAUDE_DEV_TOOLS=detach as a user env var so DevTools auto-opens
#    on every Claude launch.
[Environment]::SetEnvironmentVariable("CLAUDE_DEV_TOOLS", "detach", "User")
```

Then close Claude completely (including the system tray) and reopen.
DevTools should now auto-open in a separate Chromium window each time
Claude starts.

## Per-session workflow

The injected CSS lives in the renderer process. When Claude is closed
the page is gone, and the next launch needs the snippet pasted again.
**There is no way to avoid this without modifying `app.asar`** -- and
that's exactly what we're not doing.

Pick one of three options for the per-session paste, in order of how
much friction you're willing to trade for setup time:

### Option A -- DevTools Snippets (recommended, 3 keystrokes per session)

One-time setup: save the snippet inside DevTools' built-in *Snippets*
panel.

1. Run `.\claude-rtl.ps1 -Mode CopySnippet` (puts the snippet on your
   clipboard).
2. In Claude's DevTools, click the **Sources** tab.
3. In the left sidebar, click **>>** and select **Snippets**.
4. Right-click in the snippets pane → **New snippet**. Name it
   `Claude-RTL`.
5. Click into the editor on the right, `Ctrl+V`, then `Ctrl+S` to save.

Per-session: in DevTools, press **`Ctrl+P`**, type `!Claude-RTL`,
press `Enter`. Done.

The snippet is saved inside DevTools' own profile and persists across
Claude restarts and Microsoft Store updates.

### Option B -- One-click launcher (`Claude-RTL.cmd`)

A `Claude-RTL.cmd` file is included in this repo. Double-click it (or
pin it to the taskbar):

1. Copies the snippet to your clipboard.
2. Launches Claude via the Microsoft Store activation URL.
3. When DevTools auto-opens, click the **Console** tab, `Ctrl+V`,
   `Enter`.

To pin to taskbar: right-click `Claude-RTL.cmd` → *Show more options*
→ *Pin to taskbar*. (Windows 11 may make you create a shortcut first
and pin the shortcut instead.)

### Option C -- Manual paste each session

Run `.\claude-rtl.ps1 -Mode CopySnippet` whenever you launch Claude,
then `Ctrl+V` and `Enter` in the DevTools Console.

## Modes

| Mode | What it does |
|---|---|
| `Status` (default) | Read-only. Shows version, run state, current `allowDevTools` value. |
| `EnableDevMode` | Backs up `config.json`, sets `allowDevTools = true`. |
| `DisableDevMode` | Backs up `config.json`, removes the `allowDevTools` key. |
| `CopySnippet` | Puts the injection snippet on your clipboard. |
| `PrintSnippet` | Prints the snippet to stdout. |

All modes accept `-NoConfirm` to skip Y/N prompts.

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
├── styles/
│   └── rtl.css                  the CSS that gets injected
├── scripts/
│   └── inject-snippet.js        the snippet that goes into DevTools
├── docs/
│   └── SECURITY.md              threat-model write-up
├── CHANGELOG.md
└── README.md
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| DevTools doesn't auto-open | `CLAUDE_DEV_TOOLS` env var didn't propagate to Explorer | Sign out + back in, or open Claude via `Claude-RTL.cmd` which inherits the env var from PowerShell |
| `Ctrl+Alt+I` does nothing in Claude | Hebrew keyboard layout intercepts `Ctrl+Alt` as `AltGr` | Switch to English layout (`Win+Space`) before pressing, or rely on the auto-open env var instead |
| Hamburger menu hidden behind window-controls overlay | Windows RTL OS locale flips title-bar buttons | The snippet adds inline-start padding via the WCO API; falls back to 140px if WCO API is unavailable |
| Snippet runs but no visual change | An older version is loaded -- clear with `claudeRtlRemove()` then re-paste current snippet |
| Lists with mixed-language items split visually (marker right, content drifting left) | Older snippet (≤ v10) -- update to current `scripts/inject-snippet.js` |
| Chat composer doesn't flip direction when typing Hebrew | Older snippet (≤ v11) without input coverage -- update to current snippet |
| `Set-Clipboard` not found in PowerShell | Very old PowerShell -- use `-Mode PrintSnippet` and copy by hand |

## Contributing

Bug reports and PRs welcome. If you find a Claude Desktop UI element
that isn't handled (lists with weird structures, custom pickers,
embedded webviews), open an issue with a screenshot and the output of
the diagnostic snippet from CHANGELOG.md's v6/v7 sections.

## License

MIT.
