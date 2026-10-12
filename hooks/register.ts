import type { Register } from 'claude-code'

/**
 * /rtl -- apply the RTL snippet to every Claude Desktop view.
 *
 * Why a slash command at all: the previous trigger was a global Ctrl+Alt+R
 * hotkey, which fires wherever the keyboard happens to be pointing. Running
 * it from inside Claude removes that whole class of surprise, and the mod is
 * a supported extension point rather than a .lnk with a hotkey attached.
 *
 * The injection itself is scripts/cdp-inject.ps1: it talks to Electron's
 * main-process inspector over a local socket and evaluates the snippet in
 * every webContents. It synthesizes no clicks and no keystrokes, so it
 * cannot steal focus or type into another application.
 */

const INJECTOR = 'scripts/cdp-inject.ps1'
const SNIPPET = 'scripts/inject-snippet.js'
const TIMEOUT_MS = 120_000

/** Across sessions: the snippet version the user was last told about. */
const VERSION_KEY = 'claude-rtl:snippet-version'

/** The inspector is opened by the user once per Claude run; say so plainly. */
const ENABLE_HINT =
  'Open it once for this Claude run, then run /rtl again:\n' +
  '  hamburger menu -> Developer -> Enable Main Process Debugger'

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'rtl',
      description: 'Apply Hebrew/RTL rendering to every Claude Desktop view',
    })

    const started = await next(e)

    // The practical workflow is DevTools + Ctrl+Enter on a SAVED copy of the
    // snippet, and that copy goes stale silently when the snippet changes --
    // which is the one real friction left. Nothing may type into DevTools for
    // the user (that is what leaked input into other apps), so instead: notice
    // the change, put the new snippet on the clipboard, and say so once.
    try {
      const source = await $.fs.read(`${$.plugin.root}/${SNIPPET}`)
      const version = /snippet \((v\d+)\)/.exec(source)?.[1]

      if (version && (await $.store.get(VERSION_KEY)) !== version) {
        const { isCopied } = await $.ui.copy({ text: source })
        $.ui.toast(
          isCopied
            ? `RTL snippet ${version} is on your clipboard - paste it over the saved DevTools snippet (Ctrl+A, Ctrl+V, Ctrl+S).`
            : `RTL snippet ${version} is available; run /rtl, or re-copy it with the launcher.`,
        )
        await $.store.set(VERSION_KEY, version)
      }
    } catch {
      // A missing or unreadable snippet must never block the session start.
    }

    return started
  })

  on('command.run', { command: 'rtl' }, async $ => {
    const root = $.plugin.root
    const { exitCode, stdout, stderr } = await $.process.run(
      [
        'powershell',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        `${root}/${INJECTOR}`,
        '-SnippetPath',
        `${root}/${SNIPPET}`,
      ],
      { timeoutMs: TIMEOUT_MS },
    )

    const out = `${stdout}\n${stderr}`

    // The injector prints one "... applied (N elements tagged ...)" line per
    // view it reached. Surfacing the count is what tells the user it actually
    // landed on the chat and not only on the window chrome.
    const applied = out
      .split('\n')
      .map(line => line.match(/applied \((\d+) elements tagged/))
      .filter((m): m is RegExpMatchArray => m !== null)

    if (applied.length > 0) {
      const tagged = applied.reduce((sum, m) => sum + Number(m[1]), 0)
      return {
        text:
          `RTL applied to ${applied.length} view(s); ${tagged} elements tagged.\n` +
          'Open a new chat later? Run /rtl again -- it is idempotent.',
      }
    }

    if (/inspector is not open/i.test(out)) {
      return { text: `The main-process inspector is closed, so nothing could be injected.\n${ENABLE_HINT}` }
    }

    return {
      text:
        `The injector did not report any view (exit ${exitCode}).\n` +
        `${ENABLE_HINT}\n\n` +
        out.trim().slice(-1500),
    }
  })
}
