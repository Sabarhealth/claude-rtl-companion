# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Launcher: auto-inject actually runs the snippet (Ctrl+Enter step)
- Screenshot-driven live debugging (window captures after every
  keystroke) revealed that on current DevTools (148), Quick Open's
  `!name` + Enter only OPENS the snippet in the Sources editor -- it
  does not run it. That is why every earlier attempt "succeeded"
  keystroke-wise yet nothing executed, and why the user's DevTools
  showed the snippet tab open.
- The sequence now ends with `Ctrl+Enter` (run the snippet open in the
  editor), verified live: green run-indicator on the snippet, Console
  drawer opened with the result, and the main window flipped to RTL.
  If Enter ever does run the snippet (older DevTools), running twice is
  harmless -- the snippet is idempotent.
- `Set-TypingTarget` gained a `SwitchToThisWindow` fallback:
  `AppActivate` alone loses to the Windows foreground lock when the
  user is actively working in another app (observed live against
  Outlook); the guard still refuses to type if focus cannot be won.

### Launcher: auto-inject fixes from live end-to-end debugging
- First real launch showed the snippet not running; live debugging on a
  running instance found two root causes:
  1. The detached DevTools window title is **"Developer Tools - <url>"**,
     not "DevTools" -- the wait loop's title pattern could never match.
  2. `CLAUDE_DEV_TOOLS=detach` did not auto-open DevTools at all on the
     current build, so there was no window to find in the first place.
- Auto-inject now: waits for the main Claude window, gives auto-open a
  10s grace, then opens DevTools itself (focus main window, switch its
  input language to en-US, send Ctrl+Alt+I -- verified working), then
  waits for the `*Developer Tools*` window and drives the Command Menu
  as before. Every keystroke target goes through the same
  focus-verify + layout-switch helper.
- `LaunchLtr` now writes a transcript to `%TEMP%\claude-rtl-launch.log`
  so failures are diagnosable when run hidden from the pinned shortcut.
- The full sequence (open DevTools via Ctrl+Alt+I -> Command Menu ->
  `!Claude-RTL` -> Enter) was executed live end-to-end on a running
  Claude Desktop 1.22209.3.0 and confirmed to reach the snippet.

### Launcher: auto-inject runs the existing `Claude-RTL` snippet name
- The auto-inject no longer requires renaming the DevTools snippet to
  `1`. It now targets the historical name `Claude-RTL` by default
  (matching existing installs; override with `-SnippetName`).
- The digit-only name was a workaround for `SendKeys` translating
  characters through the active keyboard layout. Root cause fixed
  instead: before typing, the launcher switches the DevTools window's
  input language to en-US (`LoadKeyboardLayout` +
  `WM_INPUTLANGCHANGEREQUEST`, per-window -- the rest of the desktop is
  unaffected). This also fixes a latent bug where the `Ctrl+Shift+P`
  chord itself ('p' resolves through the layout too) could mis-fire
  under a Hebrew layout.
- SendKeys metacharacters in custom snippet names are escaped.

### Launcher: zero-touch auto-inject in `LaunchLtr`
- After launching Claude, `LaunchLtr` now waits (up to 45s) for the
  detached DevTools window (`CLAUDE_DEV_TOOLS=detach`), focuses it,
  verifies via Win32 `GetForegroundWindow` that DevTools really is the
  foreground window (never types blind), and drives the DevTools
  Command Menu with synthetic keystrokes: `Ctrl+Shift+P` -> `!1` ->
  `Enter`, running the user's saved DevTools snippet named `1`.
- One-time prerequisite: save the snippet as a DevTools snippet named
  exactly `1` (Sources -> Snippets). The name must be a digit because
  `SendKeys` characters go through the active keyboard layout -- letters
  would come out as Hebrew characters under a Hebrew layout; digits are
  layout-safe.
- Every failure path (no DevTools window, focus stolen, activation
  failed) degrades gracefully with a warning; the snippet is already on
  the clipboard for manual paste.
- Combined with `InstallShortcut`, the full per-session flow is now one
  click: pinned icon -> LTR window -> DevTools opens -> snippet runs.
- Filed the ghost-pane bug upstream:
  https://github.com/anthropics/claude-code/issues/79038

### Launcher: `-Mode InstallShortcut` -- pinnable LTR launcher
- Creates a Start Menu shortcut "Claude (LTR)" with Claude's own icon
  that silently runs `-Mode LaunchLtr` (hidden PowerShell window). Pin
  it to the taskbar and launching Claude feels native again -- no
  console, no command to remember.
- `LaunchLtr` behavior change: if Claude is already running it now
  FOCUSES the existing window (like a normal app icon) instead of
  erroring -- Electron's single-instance lock would ignore the flags on
  a second launch either way.
- Verified there is no persistent alternative: the `locale` key in
  `%APPDATA%\Claude\config.json` was already `en-US` in a pre-bug
  backup, i.e. it controls app UI language only and does not stop the
  OS-locale window mirroring. Windows offers no per-app locale override
  for desktop (full-trust) apps, so the CLI flags must be applied on
  every launch -- hence the shortcut.
- Shortcut caveat: after a Microsoft Store update the icon may go
  generic (versioned exe path); the shortcut keeps working because it
  resolves the exe dynamically at launch. Re-run `InstallShortcut` to
  refresh the icon.

### Launcher: `-Mode LaunchLtr` -- ghost preview-pane workaround
- New launcher mode that starts Claude Desktop with
  `--lang=en-US --force-ui-direction=ltr`, forcing an unmirrored (LTR)
  window frame on Hebrew/Arabic Windows display languages.
- Motivation: on RTL-mirrored Windows, Claude Desktop draws its embedded
  browser/preview pane twice -- the live webview in one coordinate space
  and a snapshot layer in the mirrored one -- so a ghost copy of the pane
  floats over the chat (disappears when the pane has focus, returns on
  blur). Confirmed to reproduce with NO snippet injected (clean app
  restart), i.e. an upstream app bug, not an injection side effect.
- The mode resolves the MSIX executable dynamically from the package
  manifest (survives Store version bumps), copies the snippet to the
  clipboard, and refuses to run while Claude is already open --
  Electron's single-instance lock makes a second launch ignore CLI
  flags, so the flags would silently do nothing.
- `Claude-RTL.cmd` now delegates to `-Mode LaunchLtr` instead of
  activating the app via `shell:AppsFolder` (which cannot pass CLI
  arguments).
- Side effect of `--lang=en-US`: window controls return to the right,
  so the snippet's title-bar padding fallback correctly stays inactive.

### v17 (snippet) -- live epitaxy class inventory coverage
- Coverage extended using a class-name inventory dumped from the running
  Claude Desktop app (`[class*="epitaxy-"]` scan):
  - `.epitaxy-user-turn` -- the user's own message bubble. It is plain
    div text (no `<p>`), so the semantic tag set never matched it and
    Hebrew user messages stayed LTR. Now tagged `dir="rtl"` when they
    contain Hebrew, like the other epitaxy cards.
  - `.epitaxy-codeblock` / `.epitaxy-diff` -- Claude's code and diff
    containers. "codeblock" has no hyphen, so the generic
    `[class*="code-block"]` patterns did NOT match them. Both join the
    tagging skip-list and the forced-LTR CSS explicitly.
  - `.epitaxy-prompt-input` -- the composer, now covered by its own
    class in the input selector and CSS instead of relying only on
    contenteditable/framework-class heuristics.
- Removal helper updated accordingly (user-turn bubbles and prompt-input
  are cleaned up on `claudeRtlRemove()`).
- Harness grew to 31 assertions (user bubble, codeblock-as-divs, diff
  container, prompt-input-by-class). Zero attribute churn re-verified.

### Removed
- `styles/rtl.css` and the launcher's `-CssPath` parameter: dead since
  the snippet began embedding its own CSS. The file had drifted (v9-era
  copy, no button/table/epitaxy coverage) and nothing consumed it --
  `-CssPath` was parsed but never read. README and SECURITY.md updated
  to match.

### v16 (snippet) -- stateless re-evaluation; simulation test harness
- Added `test/simulation.html`: a 27-assertion harness that mimics Claude
  Desktop's rendering (Tailwind-prose absolute `::before` list markers,
  Claude-shipped `dir="ltr"` attributes, epitaxy cards, a composer,
  streaming mutations, code blocks). Serve the repo root over HTTP
  (`python -m http.server 8123`, or the bundled `.claude/launch.json`
  config) and open `/test/simulation.html` -- results render in-page and
  in `window.__rtlResults`. Run it before bumping any snippet version.
- The harness proved v15 still had six holes, all one bug class: the
  `:not([dir])` selectors treated "has a dir attribute" as "already
  processed", so elements Claude shipped with `dir="ltr"` (`<p>`, `<h2>`,
  `<table>`, epitaxy cards, individual `<li>`) were never re-evaluated --
  and neither were elements the snippet itself tagged early during
  streaming: a paragraph tagged `dir="auto"` while still English-only
  stayed LTR even after Hebrew streamed in.
- v16 switches every tagging pass to stateless re-evaluation: selectors
  match all target elements, each pass computes the desired dir from
  current content, and writes only when the value actually differs
  (verified zero attribute churn across idle re-tag passes). Streamed
  content now flips direction on the next observer tick.
- `<li>`/`<p>` descendants of RTL lists get any Claude-shipped `dir`
  stripped so they inherit the list direction (the v9 marker-side lesson).
- Shipped `dir="ltr"` on pure-English block elements is left alone (it
  resolves the same as `auto`; rewriting would fight React re-renders).
- Trimmed the v11-v15 history comments from the snippet header -- the
  paste payload shrinks by ~90 lines; history lives here and in git log.

### v15 (snippet) -- override Claude-shipped `dir="ltr"` on Hebrew lists
- Numbered/bulleted lists whose first item starts with an English acronym
  (e.g. `1. SHIMI (האחרונה): ...`) were staying LTR: markers on the left,
  padding on the wrong side, whole list unreadable. Diagnostic in DevTools
  confirmed Claude Desktop ships the offending `<ol>` with `dir="ltr"`
  already set (first-strong-char auto-detect on Claude's side).
- v14 used `ul:not([dir]), ol:not([dir])` as the list selector, so it
  skipped any list with a pre-existing dir attribute -- including these
  mis-detected ones. v15 selects `ul, ol` unconditionally and skips only
  lists that are already `dir="rtl"`. If Hebrew/Arabic appears anywhere
  in the list's textContent, dir="rtl" is set, overriding Claude's ltr.
- No changes to tables, epitaxy cards, editable inputs, or CSS.

### Launcher updates (post-initial-release)
- Added `-Mode Setup` that does the full one-shot install non-interactively:
  `EnableDevMode` + sets `CLAUDE_DEV_TOOLS=detach` user env var +
  broadcasts `WM_SETTINGCHANGE` to Explorer + copies the snippet to the
  clipboard. Intended path for both manual users and automated installs
  (e.g. Claude Code running through the script).
- `EnableDevMode` no longer requires `config.json` to pre-exist. If the
  user's roaming Claude profile directory is missing, it is created.
  If `config.json` is missing, a minimal one is created with just
  `allowDevTools: true`. Claude fills in its own keys on first launch.
- Removed the `Read-Host` Y/N prompts from `EnableDevMode` and
  `DisableDevMode`. Both actions are reversible (`DisableDevMode`),
  auto-backed-up, and the user already consented by specifying the
  mode -- there was no reason to second-guess. The `-NoConfirm` switch
  is retained as a no-op for backwards compatibility.
- This unblocks the install loop reported when running the script from
  inside Claude Code's non-interactive shell, where `Read-Host` never
  received input.
- `EnableDevMode` also no longer hard-errors when Claude Desktop's MSIX
  package is not yet installed. It writes the config anyway with a
  warning so the value is in place when Claude is installed later.

### v14 (snippet) -- Claude epitaxy UI (AskUserQuestion picker, branch row)
- Extends coverage to Claude Desktop's custom UI components built on the
  internal "epitaxy" design system: the AskUserQuestion picker
  (`.epitaxy-approval-card`) and the branch info row
  (`.epitaxy-branch-row`). Those cards are constructed from
  `<button>`/`<div>` with custom class names, not from semantic
  `<p>`/`<li>`/`<td>`, so the v13 tag set never matched them. The Q&A
  picker stayed LTR even when the question and option labels contained
  Hebrew.
- v14 adds `BUTTON` to the AUTO_TAGS tag set so any `<button>` whose text
  contains Hebrew/Arabic gets `dir="rtl"`. The button's flex layout
  reorders naturally (text/icon swap sides). Pure-English buttons get
  `dir="auto"` and keep their LTR layout.
- Adds a CLAUDE_CARD_SELECTOR pass that tags
  `.epitaxy-approval-card` / `.epitaxy-branch-row` with `dir="rtl"`
  when the card's textContent has Hebrew. Descendant flex containers
  inherit RTL direction and flip their child order accordingly.
- Adds `button` to the CSS `text-align: start` rule so button label
  text follows the button's resolved direction (right for Hebrew,
  left for English) instead of Tailwind's hard-coded `text-left`.

### v13 (snippet) -- mixed-content RTL + flipped tables
- Mixed-language paragraphs now force `dir="rtl"` even when the line
  starts with English. Earlier versions tagged `<p>`, `<td>`, etc with
  `dir="auto"`, which used first-strong-char to pick a direction:
  a line like `<strong>Note</strong> שים לב` auto-detected as LTR
  because the first strong char was "N". v13 sets `dir="rtl"` whenever
  any Hebrew/Arabic character appears anywhere in the element's
  textContent. Pure-English elements still get `dir="auto"` which
  resolves to LTR, so English-only paragraphs are unchanged.
- All tables outside code blocks now get `dir="rtl"`, which flips the
  column order to right-to-left. The previous CSS rule
  `table { direction: ltr !important }` is removed; the HTML dir
  attribute is the source of truth.
- Per-cell direction is still independent. `<td>`/`<th>` get `dir="rtl"`
  if their own text has Hebrew, `dir="auto"` otherwise. A pure-English
  cell in an RTL-ordered table stays left-aligned within its cell.
- The `[dir="rtl"]` ancestor skip in step 3 was narrowed to
  `ul[dir="rtl"], ol[dir="rtl"]` only. Cells inside an RTL table are
  no longer skipped, so they get their own per-content direction.

### v12 (snippet) -- chat input direction
- Broadens CSS input selectors to cover Lexical, ProseMirror, Tiptap,
  Quill, Slate, and `[aria-label*="Message"]` editors so the chat
  composer is reliably caught across Claude Desktop builds.
- JS sets `dir="auto"` on those input elements via the same tagging
  loop used for `<p>`/`<td>`/etc, so the input flips direction once
  the first strong character is typed (Hebrew -> RTL, English -> LTR).
- Drops `unicode-bidi: plaintext` from input CSS for the same reason
  v11 dropped it from `<p>`/`<li>`: when the editor is inside an
  explicit RTL ancestor, `plaintext` would override the inherited
  direction.

### v11 (snippet) -- mixed-language items in RTL lists
- v10 had `unicode-bidi: plaintext !important` on every `<p>`, `<li>`,
  `<td>`, etc. When a `<p>` was inside a `<ul dir="rtl">`, the `<p>`
  inherited element direction RTL but `plaintext` overrode the
  paragraph base direction to "first-strong of own content". For
  English-first mixed content the paragraph direction went LTR,
  giving a broken-looking split between the right-side marker and
  left-drifting content.
- v11 keeps `dir="rtl"` on the list, no longer applies `plaintext`
  to `<p>`/`<li>` etc, and tags `<p>`/`<td>`/etc with `dir="auto"`
  only when they are NOT inside an `[dir="rtl"]` ancestor. Inside
  RTL lists, elements inherit RTL direction and the bidi algorithm
  handles mixed Hebrew+English chunks within each line naturally.

### Changed in v10 (snippet) -- real-time tagging
- v9's tagAuto re-ran on a 3-second `setInterval`, leaving a 0--3 second
  gap between new content arriving and getting tagged. Visible for things
  like AskUserQuestion picker UIs and freshly-streamed assistant messages
  -- the bullet would render on the wrong side until the next interval.
- v10 adds a debounced `MutationObserver` on `document.body` that schedules
  a 200ms timeout on the first mutation in a burst, then runs `tagAuto()`.
  Subsequent mutations during the same 200ms window are coalesced into the
  single pending run. The observer callback itself does no heavy work.
- The observer does NOT watch attribute mutations, so our own `dir="rtl"`
  writes do not feed back into the observer (avoiding v3's cascade).
- Backup `setInterval` retained at 5 seconds for resilience against
  observer disconnects.

### Changed in v9 (snippet) -- working state for list markers
- v8 set `dir="rtl"` on `<ul>`/`<ol>` containing Hebrew but ALSO set
  `dir="auto"` on each `<li>`. CSS spec places list markers at the
  inline-start of the `<li>` itself, so the `<li>`'s direction is what
  matters -- and `dir="auto"` overrides any inherited direction. List
  items that started with English (e.g. an HTML tag in code formatting)
  detected as LTR, so markers stayed on the left even when the
  surrounding list was RTL.
- v9 keeps `dir="rtl"` on the list container but does NOT tag `<li>`.
  With no `dir` on the items, they inherit the list's direction. RTL
  list -> RTL `<li>` -> marker on the inline-start of the `<li>` =
  right edge.
- Tailwind prose draws markers as `::before` with
  `position: absolute; left: 0`, which is a physical offset that does
  not flip in RTL. v9 uses the `:dir(rtl)` pseudo-class to override
  those `::before` rules to `right: 0` whenever the computed direction
  is RTL (works for both attribute-set and inherited direction). The
  list and item `padding-left` are mirrored to `padding-right` the
  same way.
- Per-paragraph content within `<li>` still uses
  `unicode-bidi: plaintext` so a single line containing English code
  followed by Hebrew text still flows naturally as one paragraph
  rather than fragmenting.

### Changed in v8 (snippet)
- Attempted to fix list markers by tagging `<ul>`/`<ol>` with `dir="rtl"`
  via a Hebrew/Arabic content heuristic. Worked partially but markers
  still appeared on the wrong side because the per-`<li>` `dir="auto"`
  from v6/v7 overrode the inherited direction (see v9 note above).

### Changed in v7 (snippet)
- Identified the actual cause of the misplaced list markers: Claude renders
  message content with Tailwind Typography (`@tailwindcss/typography`,
  the `prose` plugin), which draws ordered- and unordered-list markers
  with `::before` pseudo-elements positioned at `position: absolute;
  left: 0`. `left` is a *physical* offset, not a logical one. Setting
  `dir="auto"` on the `<li>` correctly flips text direction, but the
  absolutely-positioned pseudo-marker stays glued to the left edge.
- v7 hides the prose `::before` markers (`display: none !important;
  content: none !important`) and uses the browser's native list markers
  with `list-style-position: inside`, so the marker joins the bidi text
  flow and the browser positions it according to the element's direction.
  Native markers natively respect `dir="auto"`.
- v7 also resets the prose-applied `padding-left` on `<li>` (which existed
  to make room for the absolute `::before` markers) so RTL text is no
  longer pushed away from the right edge.

### Changed in v6 (snippet)
- v5 used `* { unicode-bidi: plaintext !important }`. That applied the
  property to inline elements (span, strong, em, code, a) inside paragraphs
  too. Inline elements with `plaintext` become their own bidi paragraphs,
  which fragments mixed-content lines: a bullet item containing `<strong>`
  English keywords plus surrounding Hebrew text rendered as a stack of
  orphaned fragments, with bullets visually disconnected from their text.
- v6 scopes `unicode-bidi: plaintext` to block-level text containers only:
  `p, li, dt, dd, blockquote, td, th, summary, figcaption, caption, h1-h6`.
  Inline elements keep their default bidi behavior so mixed-language text
  inside a paragraph flows as a single line.
- Otherwise carries over v5: `dir="auto"` on those same block elements as
  the load-bearing mechanism, `setInterval` re-tag every 3s, no subtree
  observer, table column-order LTR.

### Changed in v5 (snippet)
- v4's pure-CSS approach to list markers (`* { unicode-bidi: plaintext }` +
  `list-style-position: inside`) lost the cascade against Claude's Tailwind
  prose CSS, which has higher specificity with `!important` on `<li>`. Lines
  inside lists rendered LTR even when content was Hebrew, leaving the
  marker on the wrong side.
- v4 also did nothing for tables; Claude inherits `direction: rtl` from a
  locale-aware Tailwind path, which flips column order from source.
- v5 sets HTML `dir="auto"` on `<li>`, `<p>`, `<td>`, `<th>` elements. The
  `dir` attribute is honored by the bidi algorithm below CSS-specificity,
  so it always wins. `auto` makes the browser auto-detect direction per
  element from the first strong character, so English and Hebrew items in
  the same list each get the right direction.
- v5 adds `table, thead, tbody, tfoot, tr, colgroup { direction: ltr
  !important }` so column order is preserved; per-cell direction is
  handled by `dir="auto"` on each `<td>`/`<th>`.
- v5 replaces v4's `MutationObserver` over `document.head` with a
  `setInterval` (3s) that re-runs the small `querySelectorAll` to tag
  newly-rendered list items. No subtree observer at all; the only
  observer left watches `document.head.childList` for re-adding the
  `<style>` if Claude removes it.
- `claudeRtlRemove()` cleans up the `dir="auto"` attributes we added (only
  on the four element tags we target, by tagName whitelist).

### Changed in v4 (snippet)
- v3 froze Claude. Two root causes:
  1. The MutationObserver watched `document.documentElement` with
     `subtree:true` and ran a TreeWalker plus a title-bar querySelector on
     every batch. Claude's React SPA produces thousands of mutations per
     second, so the observer callback became the dominant load.
  2. Setting `dir="rtl"` on text-bearing descendants of `<table>` cells
     interacted with React's reconciliation and ended up flipping table
     column order on the next render.
- v4 reverts to pure CSS. No DOM walker, no `dir` attributes added. List
  markers move to the correct side via `list-style-position: inside`,
  which puts the marker in the line box so the bidi algorithm positions
  it from the line's first strong character. Trade-off: English lists
  also get inside markers (slightly different visual layout, no
  functional issue).
- v4's MutationObserver watches only `document.head` with `childList:true`,
  and only re-adds the `<style>` if Claude removes it. `document.head`
  doesn't churn, so this observer is essentially idle.
- Title-bar pad is now applied once + on `geometrychange`, not on every
  mutation. A bounded retry covers the case where `.draggable` isn't
  present on the first frame.

### Changed in v3 (snippet)
- Snippet now walks the DOM, detects Hebrew/Arabic text, and tags the
  immediate text-bearing host with `dir="rtl"`. It also propagates
  `dir="rtl"` to the closest `<ul>`/`<ol>` ancestor so list markers
  (1., 2., 3., bullets) move to the correct side. v2's blanket `*`
  selector did not solve this; v3 uses targeted CSS plus DOM tagging.
- Snippet adds title-bar overlap fix using the
  `navigator.windowControlsOverlay` API: when the OS draws window
  controls on the inline-start side (Hebrew/Arabic locale on Windows
  11), it queries `getTitlebarAreaRect()` and applies
  `padding-inline-start` to the `.draggable:not(.draggable-none)` drag
  region so the menu button is no longer covered. Falls back to 140px
  padding when the WCO API is unavailable but the locale is RTL.
- CSS now mirrors the targeted approach informed by
  shraga100/claude-desktop-rtl-patch's runtime fix, reimplemented as a
  console snippet so we never modify `app.asar`. Code blocks get
  `direction:ltr; unicode-bidi:isolate` explicitly.
- Snippet exposes `claudeRtlRemove()` that also cleans up the
  `dir` attributes we added and the title-bar padding we set.

### Added
- Initial launcher `claude-rtl.ps1` with five modes:
  `Status`, `EnableDevMode`, `DisableDevMode`, `CopySnippet`, `PrintSnippet`.
- `styles/rtl.css` -- conservative bidirectional CSS using
  `unicode-bidi: plaintext` on text-bearing elements only. Code blocks
  are kept LTR explicitly.
- `scripts/inject-snippet.js` -- the snippet that goes into Claude
  Desktop's DevTools Console. Idempotent, includes `claudeRtlRemove()`
  for in-session undo, installs a `MutationObserver` to survive
  SPA route swaps.
- `docs/SECURITY.md` -- threat-model write-up explaining why the
  approach does not trip antivirus / EDR the way `app.asar` patching
  does.
- Atomic `config.json` editing with timestamped `.bak` backup before
  every write. Edits exactly one key (`allowDevTools`).
- Status mode that prints whether Claude is installed, whether it is
  running, and the current value of `allowDevTools`, with a numbered
  next-steps list.
- `Set-Clipboard` integration so `CopySnippet` puts the snippet on the
  clipboard and prints the five paste keystrokes.

### Changed
- Approach pivoted away from `--remote-debugging-port` + Chrome DevTools
  Protocol injection after verifying that Electron 30+ (Claude is on
  Electron 41.5.0) strips the flag at the CLI level before application
  JavaScript runs. The new approach uses the application's own
  officially-shipped Developer Mode feature, which writes the same
  config-file key the in-app menu writes.

### Removed
- The original CDP injector (`Send-CdpCommand`, `Receive-CdpResponse`,
  `Page.addScriptToEvaluateOnNewDocument`, `Runtime.evaluate`,
  `Watch` mode) -- unused on the current Electron build.
- The Win32 `PostMessage(WM_CLOSE)` graceful-close P/Invoke -- no
  longer needed because the script no longer launches Claude itself.
