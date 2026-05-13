// =============================================================================
// Claude RTL Companion -- DevTools console snippet (v13)
// =============================================================================
// v13 changes two tagging behaviors per user request:
//
// 1. Mixed-language paragraphs now force RTL even when the line starts with
//    English. Previously a paragraph like "<strong>Note</strong> שים לב"
//    auto-detected to LTR because the first strong char was English. v13
//    sets dir="rtl" whenever any Hebrew/Arabic character appears anywhere
//    in the element's text content. Pure-English content stays dir="auto"
//    (which resolves to LTR), so English-only lines are unchanged.
//
// 2. All tables (outside code blocks) get dir="rtl" so the column order
//    flips to RTL. Per-cell text alignment is independent: <td>/<th> still
//    get dir="rtl"/auto based on their own content, so a pure-English cell
//    stays left-aligned within the RTL-ordered table.
//
// The previous CSS rule that forced `table { direction: ltr !important }`
// is removed; the new HTML dir attribute on each table is now the source
// of truth for column direction.
// =============================================================================
//
// v12 extended v11 to cover the chat input area. Claude Desktop's composer is
// a rich-text editor (likely Lexical or ProseMirror in practice) and the
// generic textarea/contenteditable selectors didn't reliably catch it across
// builds. v12:
//   - Broadens the CSS input selectors (Lexical, ProseMirror, Tiptap,
//     [aria-label*="Message"], [data-slate-editor], etc.).
//   - Tags those input elements with `dir="auto"` via JS so the input flips
//     direction once the first strong character is typed: Hebrew ->RTL,
//     English -> LTR. text-align: start follows the resolved direction.
//   - Drops `unicode-bidi: plaintext` from input CSS for the same reason
//     v11 dropped it from <p>/<li>: when the editor is inside an explicit
//     RTL ancestor, plaintext would override the inherited direction.
// =============================================================================
// v11 fixes the issue v10 introduced where list items containing English-first
// mixed-language content rendered the marker on the right side of the list
// (correct) but the content drifted to the left as a separate-looking
// paragraph (broken).
//
// Root cause: v10 had `unicode-bidi: plaintext !important` on every <p>, <li>,
// <td>, etc. When a <p> was inside a <ul dir="rtl">, the <p>:
//   - inherited element direction RTL
//   - but `plaintext` overrode the paragraph base direction to "first-strong
//     of own content"
//   - first-strong of "picker UI של שאלה ..." is "p" (English) -> paragraph
//     direction LTR
//   - element direction RTL (right alignment) and paragraph direction LTR
//     (text flows L->R) gave a broken-looking visual split.
//
// v11 strategy:
//   1. JS tags <ul>/<ol> with dir="rtl" if their text has Hebrew/Arabic.
//   2. JS tags <p>, <td>, <th>, <h1-h6>, etc with dir="auto" -- BUT only
//      when they are NOT inside a [dir="rtl"] ancestor. Items inside a
//      Hebrew list inherit RTL direction from the list, and the bidi
//      algorithm handles mixed Hebrew+English chunks within the line
//      naturally (LTR runs nested inside an RTL paragraph).
//   3. CSS no longer sets `unicode-bidi: plaintext`. It only sets
//      `text-align: start` (which follows the element's resolved
//      direction) and the list-marker overrides for RTL contexts.
//   4. Real-time MutationObserver (200ms debounce) and a 5s setInterval
//      backup carry over from v10.
// =============================================================================

(function () {
  const STYLE_ID = 'claude-rtl-companion';

  const css = `
/* All block text containers align by their resolved direction */
p, li, dt, dd, blockquote, td, th, summary, figcaption, caption,
h1, h2, h3, h4, h5, h6 {
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
                     'SUMMARY', 'FIGCAPTION', 'CAPTION'];
  const AUTO_SELECTOR = AUTO_TAGS.map(t => t.toLowerCase() + ':not([dir])').join(',');
  const RTL_RX = /[֐-׿؀-ۿ܀-ݏހ-޿]/;

  // Editable surface selector: covers textarea, generic contenteditable,
  // and rich-text editor frameworks (Lexical, ProseMirror, Tiptap, Quill,
  // Slate). aria-label heuristics catch composers that don't expose a
  // specific framework class.
  const INPUT_SELECTOR = [
    'textarea:not([dir])',
    'input[type="text"]:not([dir])',
    'input[type="search"]:not([dir])',
    'input[type="email"]:not([dir])',
    'input[type="url"]:not([dir])',
    'input:not([type]):not([dir])',
    '[contenteditable="true"]:not([dir])',
    '[contenteditable=""]:not([dir])',
    '[role="textbox"]:not([dir])',
    '.ProseMirror:not([dir])',
    '.tiptap:not([dir])',
    '.ql-editor:not([dir])',
    '[data-lexical-editor]:not([dir])',
    '[data-slate-editor="true"]:not([dir])'
  ].join(',');

  function tagAuto() {
    let n = 0;
    try {
      // 1. Lists with Hebrew/Arabic content -> dir="rtl" (markers go right).
      const lists = document.querySelectorAll('ul:not([dir]), ol:not([dir])');
      for (const list of lists) {
        if (list.closest('pre, code, [class*="code-block"], [class*="CodeBlock"]')) continue;
        if (RTL_RX.test(list.textContent || '')) {
          list.setAttribute('dir', 'rtl');
          n++;
        }
      }
      // 2. Tables: ALL get dir="rtl" so column order flows right-to-left.
      //    Per-cell direction is set independently below so pure-English
      //    cells still align left.
      const tables = document.querySelectorAll('table:not([dir])');
      for (const table of tables) {
        if (table.closest('pre, code, [class*="code-block"], [class*="CodeBlock"]')) continue;
        table.setAttribute('dir', 'rtl');
        n++;
      }
      // 3. Block text containers:
      //    - Skip elements inside RTL <ul>/<ol> (they should inherit list direction)
      //    - For everything else: rtl if any Hebrew/Arabic anywhere in the
      //      text (mixed lines included), auto otherwise (resolves to LTR
      //      for pure English).
      //    NOTE: we do NOT skip descendants of RTL tables, because we want
      //    per-cell direction so English cells in an RTL-ordered table
      //    stay left-aligned within the cell.
      const els = document.querySelectorAll(AUTO_SELECTOR);
      for (const el of els) {
        if (el.closest('pre, code, [class*="code-block"], [class*="CodeBlock"]')) continue;
        if (el.closest('ul[dir="rtl"], ol[dir="rtl"]')) continue;
        const text = el.textContent || '';
        if (RTL_RX.test(text)) {
          el.setAttribute('dir', 'rtl');
        } else {
          el.setAttribute('dir', 'auto');
        }
        n++;
      }
      // 4. Editable inputs: dir="auto" so direction flips per first typed
      //    character. Empty inputs resolve to LTR by default.
      const inputs = document.querySelectorAll(INPUT_SELECTOR);
      for (const inp of inputs) {
        if (inp.closest('pre, code, [class*="code-block"], [class*="CodeBlock"]')) continue;
        inp.setAttribute('dir', 'auto');
        n++;
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
          tag === 'UL' || tag === 'OL' || tag === 'TABLE') {
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

  return 'Claude RTL v13 applied (' + initialTagged + ' elements tagged; mixed-content RTL, tables flipped). Run claudeRtlRemove() to undo.';
})();
