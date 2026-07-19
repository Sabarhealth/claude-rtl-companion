// =============================================================================
// Claude RTL Companion -- DevTools console snippet (v16)
// =============================================================================
// v16 generalizes v15's lesson to EVERY tagging pass. A simulation harness
// (test/simulation.html) proved v15 still had six holes, all one bug class:
// the `:not([dir])` selectors treated "has a dir attribute" as "already
// processed", so any element Claude Desktop shipped with dir="ltr" -- and any
// element WE tagged early during streaming -- was never re-evaluated.
//
// Failures found by the harness against v15:
//   - <p dir="ltr">, <h2 dir="ltr">, <table dir="ltr">, epitaxy card with
//     shipped dir: all skipped, stayed LTR despite Hebrew content.
//   - <li dir="ltr"> inside a Hebrew list: kept its explicit ltr, breaking
//     marker-side inheritance (the v9 lesson).
//   - Streaming: a paragraph tagged dir="auto" while still English-only was
//     never re-checked when Hebrew streamed in later -- it stayed LTR.
//
// v16 strategy -- stateless re-evaluation:
//   - Selectors match ALL target elements (no :not([dir]) state-marker).
//   - Every pass computes the desired dir from current content and writes
//     only when the value actually differs (cheap, React-churn-friendly,
//     and streaming-safe: content changes flip the dir on the next tick).
//   - Shipped dir="ltr" on pure-English block elements is left alone (it
//     resolves the same as "auto"; rewriting would just fight React).
//   - li/p descendants of our RTL lists get any shipped dir stripped so
//     they inherit the list direction (marker side follows the li).
// ponytail: full re-scan each pass; if very long chats ever lag, fast-path
// elements whose textContent length is unchanged.
//
// Full per-version history (v3..v16, incl. the v9 marker-inheritance and v11
// plaintext lessons) lives in CHANGELOG.md and git log -- not here, to keep
// the DevTools paste payload small.
// Verify changes against test/simulation.html (27 assertions) before bumping.
// =============================================================================

(function () {
  const STYLE_ID = 'claude-rtl-companion';

  const css = `
/* All block text containers align by their resolved direction */
p, li, dt, dd, blockquote, td, th, summary, figcaption, caption,
h1, h2, h3, h4, h5, h6, button {
  text-align: start !important;
}

/* Editable surfaces -- broad coverage for the chat composer.
   text-align:start follows the element's resolved direction (set by JS to
   dir="auto" so it adapts to typed content). We do NOT use unicode-bidi:
   plaintext here for the same reason as <p>/<li>: it would override
   inherited direction when the editor is inside an RTL ancestor. */
textarea,
input[type="text"], input[type="search"], input[type="email"],
input[type="url"], input:not([type]),
[contenteditable="true"], [contenteditable=""],
[role="textbox"],
.ProseMirror, .tiptap, .ql-editor,
[data-lexical-editor], [data-lexical-editor="true"],
[data-slate-editor="true"], [data-slate-node="value"],
[aria-label*="Message" i], [aria-label*="message" i],
[aria-label*="Reply" i], [aria-label*="reply" i],
[aria-label*="Compose" i], [aria-label*="compose" i],
[aria-label*="Type" i], [placeholder] {
  text-align: start !important;
}

/* Tables: column direction comes from the dir attribute we set per-table in
   JS (chat tables -> dir="rtl"). The thead/tbody/tfoot/tr/colgroup children
   inherit table direction; no CSS override needed. */

/* List markers for RTL contexts.
   Tailwind prose draws markers as ::before with position:absolute and left:0
   (a physical offset). Flip them to right:0 when computed direction is RTL. */
li:dir(rtl)::before {
  left: auto !important;
  right: 0 !important;
}

/* Mirror Tailwind's left padding to right padding for RTL lists/items. */
ul:dir(rtl), ol:dir(rtl) {
  padding-left: 0 !important;
  padding-right: 1.625em !important;
}
ul:dir(rtl) > li, ol:dir(rtl) > li {
  padding-left: 0 !important;
  padding-right: 0.375em !important;
}

/* Code blocks always LTR */
pre, code, .code-block__code, [class*="code-block"], [class*="CodeBlock"] {
  unicode-bidi: isolate !important;
  direction: ltr !important;
  text-align: left !important;
}
pre *, code *, .code-block__code *, [class*="code-block"] *, [class*="CodeBlock"] * {
  unicode-bidi: isolate !important;
  direction: ltr !important;
}

/* Title-bar drag region marker (set by JS) */
.draggable[data-claude-rtl-padded] {
  box-sizing: border-box !important;
}
`;

  // --------------------------------------------------------------------------
  // 1. Apply CSS
  // --------------------------------------------------------------------------
  function applyCss() {
    const old = document.getElementById(STYLE_ID);
    if (old) old.remove();
    const style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = css;
    (document.head || document.documentElement).appendChild(style);
  }

  // --------------------------------------------------------------------------
  // 2. Tagging
  // --------------------------------------------------------------------------
  const AUTO_TAGS = ['P', 'TD', 'TH', 'DT', 'DD', 'BLOCKQUOTE',
                     'H1', 'H2', 'H3', 'H4', 'H5', 'H6',
                     'SUMMARY', 'FIGCAPTION', 'CAPTION', 'BUTTON'];
  // v16: no :not([dir]) state-marker -- every pass re-evaluates all targets
  // from current content and writes only on change (see setDir).
  const AUTO_SELECTOR = AUTO_TAGS.map(t => t.toLowerCase()).join(',');
  const RTL_RX = /[֐-׿؀-ۿ܀-ݏހ-޿]/;
  const IN_CODE = 'pre, code, [class*="code-block"], [class*="CodeBlock"]';

  // Claude Desktop's custom UI containers (the "epitaxy" design system).
  // These cards/rows use <button>/<div>/<span> with custom classes rather
  // than semantic tags, so AUTO_SELECTOR alone misses them. We tag the
  // outer card with dir="rtl" when it contains Hebrew; flex/grid layouts
  // inside the card reorder naturally based on inherited direction.
  const CLAUDE_CARD_SELECTOR = '.epitaxy-approval-card, .epitaxy-branch-row';

  // Editable surface selector: covers textarea, generic contenteditable,
  // and rich-text editor frameworks (Lexical, ProseMirror, Tiptap, Quill,
  // Slate). aria-label heuristics catch composers that don't expose a
  // specific framework class.
  const INPUT_SELECTOR = [
    'textarea',
    'input[type="text"]',
    'input[type="search"]',
    'input[type="email"]',
    'input[type="url"]',
    'input:not([type])',
    '[contenteditable="true"]',
    '[contenteditable=""]',
    '[role="textbox"]',
    '.ProseMirror',
    '.tiptap',
    '.ql-editor',
    '[data-lexical-editor]',
    '[data-slate-editor="true"]'
  ].join(',');

  // Write dir only when it actually changes. Keeps passes idempotent and
  // cheap, avoids fighting React re-renders, and lets streamed content flip
  // an element's direction on a later tick.
  function setDir(el, want) {
    if (el.getAttribute('dir') === want) return 0;
    el.setAttribute('dir', want);
    return 1;
  }

  function tagAuto() {
    let n = 0;
    try {
      // 1. Lists: Hebrew/Arabic anywhere -> dir="rtl", overriding any
      //    Claude-shipped dir (Claude first-strong-detects per element and
      //    mis-labels English-first mixed lists as ltr).
      for (const list of document.querySelectorAll('ul, ol')) {
        if (list.closest(IN_CODE)) continue;
        if (RTL_RX.test(list.textContent || '')) n += setDir(list, 'rtl');
      }
      // 1b. li/p descendants of our RTL lists must INHERIT the list
      //     direction (v9 lesson: the li's own direction decides the marker
      //     side). Strip any dir Claude shipped on them.
      for (const el of document.querySelectorAll(':is(ul, ol)[dir="rtl"] :is(li, p)[dir]')) {
        el.removeAttribute('dir');
        n++;
      }
      // 2. Tables: ALL get dir="rtl" so column order flows right-to-left
      //    (v13 decision), shipped dir included. Per-cell direction is set
      //    independently below so pure-English cells still align left.
      for (const table of document.querySelectorAll('table')) {
        if (table.closest(IN_CODE)) continue;
        n += setDir(table, 'rtl');
      }
      // 2b. Claude Desktop UI cards (AskUserQuestion picker, branch row).
      for (const card of document.querySelectorAll(CLAUDE_CARD_SELECTOR)) {
        if (card.closest(IN_CODE)) continue;
        if (RTL_RX.test(card.textContent || '')) n += setDir(card, 'rtl');
      }
      // 3. Block text containers:
      //    - Skip elements inside RTL <ul>/<ol> (they inherit list direction)
      //    - rtl if any Hebrew/Arabic anywhere in the text, auto otherwise.
      //    - A shipped dir="ltr" on non-RTL content is left alone: it
      //      resolves the same as "auto" and rewriting would churn the DOM.
      //    NOTE: we do NOT skip descendants of RTL tables, because we want
      //    per-cell direction so English cells in an RTL-ordered table
      //    stay left-aligned within the cell.
      for (const el of document.querySelectorAll(AUTO_SELECTOR)) {
        if (el.closest(IN_CODE)) continue;
        if (el.closest('ul[dir="rtl"], ol[dir="rtl"]')) continue;
        if (RTL_RX.test(el.textContent || '')) {
          n += setDir(el, 'rtl');
        } else {
          const cur = el.getAttribute('dir');
          if (cur !== 'auto' && cur !== 'ltr') n += setDir(el, 'auto');
        }
      }
      // 4. Editable inputs: dir="auto" so direction flips per first typed
      //    character. Overrides shipped values -- auto adapts, a fixed dir
      //    doesn't. Empty inputs resolve to LTR by default.
      for (const inp of document.querySelectorAll(INPUT_SELECTOR)) {
        if (inp.closest(IN_CODE)) continue;
        n += setDir(inp, 'auto');
      }
    } catch (_) {}
    return n;
  }

  // --------------------------------------------------------------------------
  // 3. Title-bar overlap fix (window controls overlay)
  // --------------------------------------------------------------------------
  const FALLBACK_PAD_PX = 140;

  function applyTitleBarPad() {
    const wco = navigator.windowControlsOverlay || null;
    const locale = ((navigator.language || '') + ',' + (navigator.languages || []).join(','))
      .toLowerCase();
    const localeIsRtl = /\b(he|iw|ar|fa|ur|yi|ps|sd)\b/.test(locale);

    const topBar = document.querySelector('.draggable:not(.draggable-none)');
    if (!topBar) return false;

    let padStart = 0;
    if (wco && wco.visible && typeof wco.getTitlebarAreaRect === 'function') {
      const rect = wco.getTitlebarAreaRect();
      if (rect && rect.width > 0 && rect.x === 0) {
        padStart = Math.round(rect.width);
      }
    } else if (localeIsRtl) {
      padStart = FALLBACK_PAD_PX;
    }

    if (padStart > 0) {
      topBar.style.paddingInlineStart = padStart + 'px';
      topBar.setAttribute('data-claude-rtl-padded', String(padStart));
    } else {
      topBar.style.paddingInlineStart = '';
      topBar.removeAttribute('data-claude-rtl-padded');
    }
    return true;
  }

  // --------------------------------------------------------------------------
  // 4. Idle <style> observer
  // --------------------------------------------------------------------------
  function startStyleObserver() {
    if (window.__claudeRtlObs) window.__claudeRtlObs.disconnect();
    const obs = new MutationObserver(() => {
      if (!document.getElementById(STYLE_ID)) applyCss();
    });
    obs.observe(document.head, { childList: true });
    window.__claudeRtlObs = obs;
  }

  // --------------------------------------------------------------------------
  // 5. Periodic re-tag (5s backup)
  // --------------------------------------------------------------------------
  function startTagInterval() {
    if (window.__claudeRtlTagInt) clearInterval(window.__claudeRtlTagInt);
    window.__claudeRtlTagInt = setInterval(() => {
      try { tagAuto(); } catch (_) {}
    }, 5000);
  }

  // --------------------------------------------------------------------------
  // 5b. Real-time tagging via debounced MutationObserver
  // --------------------------------------------------------------------------
  function startContentObserver() {
    if (window.__claudeRtlContentObs) {
      window.__claudeRtlContentObs.disconnect();
    }
    let pending = null;
    const obs = new MutationObserver(() => {
      if (pending) return;
      pending = setTimeout(() => {
        pending = null;
        try { tagAuto(); } catch (_) {}
      }, 200);
    });
    obs.observe(document.body || document.documentElement, {
      childList: true,
      subtree: true,
      attributes: false,
      characterData: false
    });
    window.__claudeRtlContentObs = obs;
  }

  // --------------------------------------------------------------------------
  // 6. WCO geometry change listener
  // --------------------------------------------------------------------------
  function startWcoListener() {
    const wco = navigator.windowControlsOverlay;
    if (!wco || typeof wco.addEventListener !== 'function') return;
    if (window.__claudeRtlWcoHandler) {
      try { wco.removeEventListener('geometrychange', window.__claudeRtlWcoHandler); } catch (_) {}
    }
    const h = () => { try { applyTitleBarPad(); } catch (_) {} };
    wco.addEventListener('geometrychange', h);
    window.__claudeRtlWcoHandler = h;
  }

  // --------------------------------------------------------------------------
  // 7. Bounded retry for title bar pad
  // --------------------------------------------------------------------------
  function tryApplyPadWithRetries() {
    let tries = 0;
    const max = 10;
    const tick = () => {
      const ok = applyTitleBarPad();
      tries++;
      if (!ok && tries < max) setTimeout(tick, 250);
    };
    tick();
  }

  // --------------------------------------------------------------------------
  // 8. Apply
  // --------------------------------------------------------------------------
  applyCss();
  const initialTagged = tagAuto();
  tryApplyPadWithRetries();
  startStyleObserver();
  startTagInterval();
  startContentObserver();
  startWcoListener();

  // --------------------------------------------------------------------------
  // 9. Removal helper
  // --------------------------------------------------------------------------
  window.claudeRtlRemove = () => {
    if (window.__claudeRtlObs) {
      window.__claudeRtlObs.disconnect();
      delete window.__claudeRtlObs;
    }
    if (window.__claudeRtlContentObs) {
      window.__claudeRtlContentObs.disconnect();
      delete window.__claudeRtlContentObs;
    }
    if (window.__claudeRtlTagInt) {
      clearInterval(window.__claudeRtlTagInt);
      delete window.__claudeRtlTagInt;
    }
    const wco = navigator.windowControlsOverlay;
    if (wco && window.__claudeRtlWcoHandler) {
      try { wco.removeEventListener('geometrychange', window.__claudeRtlWcoHandler); } catch (_) {}
      delete window.__claudeRtlWcoHandler;
    }
    const el = document.getElementById(STYLE_ID);
    if (el) el.remove();
    // Remove dir attributes we added. We tag specific tag groups (paragraph-
    // like containers, inputs, and certain rich-text editors). Removing
    // dir="auto" / dir="rtl" only from those tag/marker classes leaves any
    // user-authored dir on other elements intact.
    const isInputLike = (e) =>
      e.tagName === 'TEXTAREA' || e.tagName === 'INPUT' ||
      e.isContentEditable ||
      e.getAttribute('role') === 'textbox' ||
      e.matches('.ProseMirror, .tiptap, .ql-editor, [data-lexical-editor], [data-slate-editor]');

    document.querySelectorAll('[dir="auto"], [dir="rtl"]').forEach(e => {
      const tag = e.tagName;
      if (AUTO_TAGS.includes(tag) || isInputLike(e) ||
          tag === 'UL' || tag === 'OL' || tag === 'TABLE' ||
          e.matches('.epitaxy-approval-card, .epitaxy-branch-row')) {
        e.removeAttribute('dir');
      }
    });
    document.querySelectorAll('[data-claude-rtl-padded]').forEach(e => {
      e.style.paddingInlineStart = '';
      e.removeAttribute('data-claude-rtl-padded');
    });
    delete window.claudeRtlRemove;
    return 'removed';
  };

  return 'Claude RTL v16 applied (' + initialTagged + ' elements tagged; stateless re-evaluation, streaming-safe). Run claudeRtlRemove() to undo.';
})();
