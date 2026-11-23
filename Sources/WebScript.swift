import Foundation

/// The script the browser puts into every page. It finds the page's readable blocks (paragraphs, headings,
/// list items, table cells…) and numbers them in document order, so the translated page and the original beside
/// it (landscape) number them alike. In the translated page it asks the app for the blocks coming into view and
/// writes their rewritten text in place, keeping links; it reports word taps and which block is at the top, so
/// the two pages can scroll together. `window.__dfMode` ("translate" or "original") is set before it runs.
enum WebScript {
    static let source = #"""
(function () {
  if (window.__df) return;
  // Google's own pages (search results, maps…) are left as they are: in the language being learned they
  // are already searched in that language (hl=), and rewriting them adds nothing
  const onGoogle = /(^|\.)google\.(com|co\.[a-z]{2}|com\.[a-z]{2}|[a-z]{2})$/i.test(location.hostname);
  const mode = onGoogle ? 'original' : (window.__dfMode || 'translate');
  const post = (m) => { try { window.webkit.messageHandlers.df.postMessage(m); } catch (e) {} };
  const BLOCK = 'p,h1,h2,h3,h4,h5,h6,li,blockquote,dd,dt,td,th,figcaption,caption,summary,label';
  const SKIP = 'nav,script,style,noscript,code,pre,textarea,select,option,button,svg,math,[contenteditable=""],[contenteditable="true"],[aria-hidden="true"],.df-skip';
  const MEDIA = 'img,picture,svg,video,audio,iframe,canvas,input,button,select,textarea';
  const LETTERS = /\p{L}/gu;
  const blocks = [];          // id -> element
  const keys = [];            // id -> key from its original text
  const byKey = new Map();    // key -> id
  const seenText = new Map(); // text start -> how many blocks begin with it
  const original = new Map(); // id -> original innerHTML (to put a page back for a new level)
  const links = new Map();    // id -> [link elements, by marker number]
  const done = new Set();     // ids written in the language being learned
  const asked = new Set();    // ids the app has been asked for
  const seen = new Set();
  let glossaries = new Map(); // id -> glossary
  const labelled = new Set(); // lemmas whose meaning is already shown on this page
  let showNew = false;

  const letters = (s) => (s.match(LETTERS) || []).length;

  // direct text of an element, not counting its children
  function ownText(el) {
    let s = '';
    for (const n of el.childNodes) if (n.nodeType === 3) s += n.textContent;
    return s;
  }

  function candidate(el) {
    if (el.dataset.dfId !== undefined) return false;
    if (el.closest(SKIP)) return false;
    if (el.matches(BLOCK)) {
      if (el.querySelector(BLOCK)) return false;  // the inner blocks are taken instead
      return letters(el.textContent) >= 2;
    }
    // a div or span holding text of its own (many sites use them for paragraphs)
    if (el.querySelector(BLOCK + ',div')) return false;
    return letters(ownText(el)) >= 15;
  }

  function scan(root) {
    const found = [];
    const all = root.querySelectorAll(BLOCK + ',div,span');
    for (const el of all) {
      if (el.closest('[data-df-id]')) continue;
      if (candidate(el)) {
        const id = blocks.length;
        el.dataset.dfId = id; blocks.push(el); found.push(el);
        // a key from the block's text as the page wrote it, so the two pages (landscape) find the same block
        // even when scripts add things in a different order; repeated text is told apart by its count
        const k = el.textContent.replace(/\s+/g, ' ').trim().slice(0, 80);
        const n = (seenText.get(k) || 0) + 1;
        seenText.set(k, n);
        keys[id] = k + '#' + n;
        byKey.set(keys[id], id);
      }
    }
    if (mode === 'translate') for (const el of found) observer.observe(el);
  }

  // the text of a block with its links marked ⟦n⟧…⟦/n⟧
  function marked(el) {
    const ls = [];
    function walk(node) {
      let s = '';
      for (const n of node.childNodes) {
        if (n.nodeType === 3) s += n.textContent;
        else if (n.nodeType === 1) {
          if (n.matches('script,style,noscript,svg')) continue;
          if (n.tagName === 'BR') { s += ' '; continue; }
          if (n.tagName === 'A' && n.getAttribute('href') && letters(n.textContent) > 0) {
            ls.push(n.cloneNode(false));
            const k = ls.length;
            s += '⟦' + k + '⟧' + walk(n) + '⟦/' + k + '⟧';
          } else {
            // boxes inside a block (a title and a description in one link) are separated by a space
            const inline = getComputedStyle(n).display.startsWith('inline');
            s += inline ? walk(n) : ' ' + walk(n) + ' ';
          }
        }
      }
      return s;
    }
    const text = walk(el).replace(/\s+/g, ' ').trim();
    return { text, links: ls };
  }

  // ---- asking for blocks as they come into view ----
  let wanted = [];
  let timer = null;
  const observer = mode === 'translate' ? new IntersectionObserver((entries) => {
    for (const e of entries) {
      const el = e.target, id = +el.dataset.dfId;
      if (!e.isIntersecting) continue;
      if (done.has(id)) { sighted(id); continue; }
      if (asked.has(id) || e.boundingClientRect.width === 0) continue;
      asked.add(id);
      const m = marked(el);
      if (!m.text) continue;
      original.set(id, el.innerHTML);
      links.set(id, m.links);
      el.classList.add('df-pending');
      wanted.push({ id, text: m.text });
    }
    if (wanted.length && !timer) timer = setTimeout(flush, 120);
  }, { rootMargin: '0px 0px 120% 0px' }) : null;

  function flush() {
    timer = null;
    if (!wanted.length) return;
    post({ type: 'need', blocks: wanted });
    wanted = [];
  }

  function sighted(id) {
    if (seen.has(id)) return;
    const el = blocks[id];
    const r = el.getBoundingClientRect();
    if (r.top > innerHeight || r.bottom < 0) return;
    seen.add(id);
    post({ type: 'seen', id });
  }

  // ---- writing a block in the language being learned ----
  const WORD = /[\p{L}\p{M}\p{N}]+(?:['’\-][\p{L}\p{M}]+)*/gu;

  function apply(id, text, glossary) {
    const el = blocks[id];
    if (!el) return;
    el.classList.remove('df-pending', 'df-failed');
    if (text == null) { el.classList.add('df-failed'); asked.delete(id); return; }
    glossaries.set(id, glossary || []);
    const ls = links.get(id) || [];
    const media = [...el.querySelectorAll(MEDIA)];
    const frag = document.createDocumentFragment();
    for (const m of media) frag.appendChild(m);
    // split at link markers; text outside and inside links becomes word spans
    const parts = text.split(/(⟦\/?\d+⟧)/);
    let target = frag, open = null;
    const tokens = [];
    for (const part of parts) {
      const o = part.match(/^⟦(\d+)⟧$/), c = part.match(/^⟦\/(\d+)⟧$/);
      if (o) {
        const a = ls[+o[1] - 1];
        if (a) { open = a.cloneNode(false); frag.appendChild(open); target = open; }
        continue;
      }
      if (c) { target = frag; open = null; continue; }
      let last = 0;
      for (const m of part.matchAll(WORD)) {
        if (m.index > last) target.appendChild(document.createTextNode(part.slice(last, m.index)));
        const span = document.createElement('span');
        span.className = 'df-w';
        span.textContent = m[0];
        target.appendChild(span);
        tokens.push(span);
        last = m.index + m[0].length;
      }
      if (last < part.length) target.appendChild(document.createTextNode(part.slice(last)));
    }
    // glossary entries, matched to single words or runs of words
    (glossary || []).forEach((g, gi) => {
      const words = (g.w || '').toLowerCase().match(WORD) || [];
      if (!words.length) return;
      for (let i = 0; i + words.length <= tokens.length; i++) {
        let ok = true;
        for (let j = 0; j < words.length; j++) if (tokens[i + j].textContent.toLowerCase() !== words[j]) { ok = false; break; }
        if (!ok) continue;
        for (let j = 0; j < words.length; j++) {
          const t = tokens[i + j];
          if (t.dataset.g !== undefined) continue;
          t.dataset.g = gi;
          // every glossary word is probably above the reader's level: highlighted, with its meaning beside the
          // first one on the page (on the web, unlike in a book, words met on other pages are still worth showing)
          t.classList.add('df-new');
          const key = (g.lemma || g.w || '').toLowerCase();
          if (j === words.length - 1 && !labelled.has(key)) { t.dataset.m = g.m || ''; labelled.add(key); }
        }
      }
    });
    el.textContent = '';
    el.appendChild(frag);
    done.add(id);
    sighted(id);
  }

  function reset() {
    for (const id of done) { const el = blocks[id]; if (el && original.has(id)) el.innerHTML = original.get(id); }
    for (const id of asked) { const el = blocks[id]; if (el) { el.classList.remove('df-pending', 'df-failed'); if (original.has(id)) el.innerHTML = original.get(id); } }
    done.clear(); asked.clear(); seen.clear(); labelled.clear(); glossaries = new Map();
    for (const el of blocks) { observer.unobserve(el); observer.observe(el); }
  }

  // ---- taps on words ----
  function sentenceAround(el, span) {
    const text = el.textContent;
    const word = span.textContent;
    const parts = text.split(/(?<=[.!?…])\s+/);
    return parts.find((p) => p.includes(word)) || text.slice(0, 300);
  }

  function wordInfo(e) {
    const span = e.target.closest && e.target.closest('.df-w');
    if (!span) return null;
    const el = span.closest('[data-df-id]');
    if (!el) return null;
    const id = +el.dataset.dfId;
    const g = span.dataset.g !== undefined ? (glossaries.get(id) || [])[+span.dataset.g] : null;
    return { id, word: span.textContent, sentence: sentenceAround(el, span), gloss: g || null, inLink: !!span.closest('a') };
  }

  if (mode === 'translate') {
    // a tap; double-taps are seen by the app (iOS keeps the second tap for itself) and passed to wordAt below
    document.addEventListener('click', (e) => {
      const w = wordInfo(e);
      if (!w) { post({ type: 'tapOff' }); return; }
      if (w.inLink) return;
      post({ type: 'tap', id: w.id, word: w.word, sentence: w.sentence, gloss: w.gloss });
    }, true);
  }

  // the word at a point in the window, for a double-tap ("I don't know this word")
  function wordAt(x, y) {
    const el = document.elementFromPoint(x, y);
    if (!el) return false;
    const w = wordInfo({ target: el });
    if (!w || w.inLink) return false;
    const sel = window.getSelection && window.getSelection();
    if (sel) sel.removeAllRanges();
    post({ type: 'dbl', id: w.id, word: w.word, sentence: w.sentence, gloss: w.gloss });
    return true;
  }

  // ---- scrolling together (landscape) ----
  function reportTop() {
    // the first shown block whose bottom is below the top of the window (hidden blocks, such as collapsed
    // sections, have no size and are skipped)
    let best = -1;
    for (let i = 0; i < blocks.length; i++) {
      const r = blocks[i].getBoundingClientRect();
      if (r.height === 0) continue;
      if (r.bottom > 0) { best = i; break; }
    }
    if (best < 0) return;
    const r = blocks[best].getBoundingClientRect();
    post({ type: 'scroll', key: keys[best], frac: r.height > 0 ? Math.max(0, -r.top / r.height) : 0 });
  }
  let scrollQueued = false;
  addEventListener('scroll', () => {
    if (scrollQueued) return;
    scrollQueued = true;
    requestAnimationFrame(() => { scrollQueued = false; reportTop(); });
  }, { passive: true });
  const lead = () => post({ type: 'lead' });
  addEventListener('touchstart', lead, { passive: true, capture: true });
  addEventListener('wheel', lead, { passive: true, capture: true });
  addEventListener('keydown', lead, { capture: true });

  function scrollToBlock(key, frac) {
    const el = blocks[byKey.get(key)];
    if (!el) return;
    const r = el.getBoundingClientRect();
    window.scrollTo(0, scrollY + r.top + frac * r.height);
  }

  // ---- styles ----
  const style = document.createElement('style');
  style.textContent = `
    .df-w { cursor: pointer; -webkit-tap-highlight-color: transparent; }
    .df-pending { opacity: .45; transition: opacity .3s; }
    .df-shownew .df-new { background: rgba(255,170,0,.22); border-radius: 3px; }
    .df-shownew .df-new[data-m]::after { content: " (" attr(data-m) ")"; font-size: .72em; opacity: .7; font-style: italic; }
  `;
  (document.head || document.documentElement).appendChild(style);

  // ---- the app talks to the page through this ----
  window.__df = {
    apply: (list) => { for (const b of list) apply(b.id, b.text, b.glossary); },
    failed: (ids) => { for (const id of ids) apply(id, null); },
    showNew: (on) => { showNew = on; document.documentElement.classList.toggle('df-shownew', on); },
    reset,
    scrollTo: scrollToBlock,
    wordAt,
    // blocks that failed are asked for again when they are on screen
    retry: () => {
      for (const el of document.querySelectorAll('.df-failed')) {
        el.classList.remove('df-failed');
        asked.delete(+el.dataset.dfId);
        observer.unobserve(el); observer.observe(el);
      }
    },
  };

  scan(document);
  // pages that add text later (infinite scrolling, comments, apps)
  let rescan = null;
  new MutationObserver((ms) => {
    if (ms.every((m) => [...m.addedNodes].every((n) => n.nodeType !== 1 || (n.classList && n.classList.contains('df-w'))))) return;
    clearTimeout(rescan);
    rescan = setTimeout(() => scan(document), 400);
  }).observe(document.body || document.documentElement, { childList: true, subtree: true });
  post({ type: 'ready', mode, blocks: blocks.length, title: document.title });
})();
"""#
}
