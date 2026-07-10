// The Oracle phone web console — a single self-contained page served by the
// sidecar at `/`, reached through the Cloudflare Tunnel + Access in a phone
// browser. Mobile-first, no build step, calls the sidecar's same-origin `/api/*`
// (Access cookie carries auth). Kept as a string so it ships with the package
// without static-path concerns under tsx.

export const consoleHtml = /* html */ `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
<meta name="theme-color" content="#0b0d12" />
<meta name="color-scheme" content="dark" />
<!-- PWA install (add to home screen) -->
<link rel="manifest" href="/manifest.webmanifest" />
<meta name="mobile-web-app-capable" content="yes" />
<meta name="apple-mobile-web-app-capable" content="yes" />
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent" />
<meta name="apple-mobile-web-app-title" content="Oracle" />
<link rel="apple-touch-icon" href="/icon-192.png" />
<title>Oracle</title>
<style>
  :root {
    --bg: #0a0c11;
    --bg-2: #0d1017;
    --panel: #141925;
    --panel-2: #1b2231;
    --panel-hi: #232c3e;
    --line: #283041;
    --line-soft: #1e2532;
    --txt: #eef1f7;
    --dim: #98a2b6;
    --faint: #66708a;
    --tint: #8ab4ff;
    --tint-strong: #6b9bff;
    --tint-ink: #06122b;
    --good: #58e08c;
    --warn: #fcc043;
    --bad: #ff8a8a;
    --radius: 14px;
    --radius-sm: 10px;
    --tap: 46px;
    --sat: env(safe-area-inset-top);
    --sab: env(safe-area-inset-bottom);
    --sal: env(safe-area-inset-left);
    --sar: env(safe-area-inset-right);
  }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  html, body {
    margin: 0; height: 100%; background: var(--bg); color: var(--txt);
    font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility;
    overscroll-behavior-y: none;
  }
  body {
    display: flex; flex-direction: column;
    /* soft observatory glow at the top, then settle to flat */
    background:
      radial-gradient(120% 60% at 50% -10%, rgba(108,150,255,.10), transparent 60%),
      var(--bg);
    background-attachment: fixed;
    padding-left: var(--sal); padding-right: var(--sar);
  }
  button { font-family: inherit; cursor: pointer; }
  ::selection { background: rgba(138,180,255,.28); }

  /* ── Header ───────────────────────────────────────────── */
  header {
    position: sticky; top: 0; z-index: 10;
    padding: calc(var(--sat) + 12px) 16px 11px;
    display: flex; align-items: center; gap: 11px;
    background: linear-gradient(var(--bg) 62%, rgba(10,12,17,.7) 88%, transparent);
    backdrop-filter: saturate(160%) blur(8px);
    -webkit-backdrop-filter: saturate(160%) blur(8px);
  }
  .mark {
    width: 30px; height: 30px; flex: none; border-radius: 9px;
    display: grid; place-items: center; font-size: 16px; color: var(--tint);
    background: radial-gradient(120% 120% at 30% 20%, rgba(138,180,255,.22), rgba(138,180,255,.05));
    box-shadow: inset 0 0 0 1px rgba(138,180,255,.30), 0 1px 0 rgba(255,255,255,.04);
  }
  .brand { display: flex; flex-direction: column; line-height: 1.1; }
  .brand h1 { font-size: 17px; font-weight: 680; margin: 0; letter-spacing: .2px; }
  .brand .sub {
    font: 600 10.5px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
    letter-spacing: .14em; text-transform: uppercase; color: var(--faint); margin-top: 3px;
  }
  .conn {
    margin-left: auto; display: inline-flex; align-items: center; gap: 6px;
    font: 600 11px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
    letter-spacing: .06em; text-transform: uppercase; color: var(--faint);
    padding: 6px 9px; border-radius: 999px; background: var(--panel);
    box-shadow: inset 0 0 0 1px var(--line-soft);
  }
  .conn .dot {
    width: 7px; height: 7px; border-radius: 50%; background: var(--faint);
    box-shadow: 0 0 0 0 rgba(0,0,0,0); transition: background .2s;
  }
  .conn.ok .dot { background: var(--good); box-shadow: 0 0 8px rgba(88,224,140,.6); }
  .conn.bad .dot { background: var(--bad); box-shadow: 0 0 8px rgba(255,138,138,.5); }
  .conn.ok { color: var(--good); } .conn.bad { color: var(--bad); }

  /* ── Tabs ─────────────────────────────────────────────── */
  nav {
    display: flex; gap: 4px; padding: 2px; margin: 0 12px 8px;
    background: var(--panel); border-radius: 13px; box-shadow: inset 0 0 0 1px var(--line-soft);
  }
  nav button {
    flex: 1; min-height: 40px; border: 0; border-radius: 11px; background: transparent;
    color: var(--dim); font-size: 14px; font-weight: 640; letter-spacing: .1px;
    transition: color .15s, background .15s, box-shadow .15s;
  }
  nav button.active {
    background: var(--panel-hi); color: var(--txt);
    box-shadow: inset 0 0 0 1px var(--line), 0 1px 2px rgba(0,0,0,.3);
  }
  nav button:active { transform: translateY(.5px); }

  main { flex: 1; overflow-y: auto; -webkit-overflow-scrolling: touch; padding: 4px 12px; }
  .tab { display: none; padding-bottom: calc(var(--sab) + 20px); }
  .tab.active { display: block; animation: fade .22s ease; }
  @keyframes fade { from { opacity: 0; transform: translateY(4px); } to { opacity: 1; transform: none; } }

  /* ── Section heading ──────────────────────────────────── */
  .sec-head {
    display: flex; align-items: center; gap: 8px; margin: 14px 2px 8px;
    font: 600 11px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
    letter-spacing: .16em; text-transform: uppercase; color: var(--faint);
  }
  .sec-head::after { content: ""; flex: 1; height: 1px; background: var(--line-soft); }
  .sec-head .count {
    color: var(--dim); background: var(--panel); padding: 2px 7px; border-radius: 999px;
    box-shadow: inset 0 0 0 1px var(--line-soft); letter-spacing: .04em;
  }

  /* ── Cards ────────────────────────────────────────────── */
  .card {
    background: linear-gradient(180deg, var(--panel), var(--panel) 70%, var(--bg-2));
    border: 1px solid var(--line); border-radius: var(--radius);
    padding: 13px 14px; margin-bottom: 9px;
  }
  .item { transition: border-color .15s, transform .08s; }
  .item:active { transform: scale(.992); border-color: var(--line); }
  .row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  .id {
    font: 600 12px ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--tint);
    letter-spacing: .01em;
  }
  .title { font-weight: 600; font-size: 15.5px; line-height: 1.35; }
  .meta {
    color: var(--dim); font-size: 12.5px; margin-top: 6px;
    display: flex; gap: 6px 12px; flex-wrap: wrap; align-items: center;
  }
  .meta .mono { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--faint);
    max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .badge {
    font: 700 10.5px/1 ui-monospace, SFMono-Regular, Menlo, monospace; letter-spacing: .04em;
    padding: 4px 8px; border-radius: 999px; white-space: nowrap; text-transform: uppercase;
  }
  .b-ready { background: rgba(88,224,140,.15); color: var(--good); box-shadow: inset 0 0 0 1px rgba(88,224,140,.25); }
  .b-open  { background: rgba(138,180,255,.14); color: var(--tint); box-shadow: inset 0 0 0 1px rgba(138,180,255,.22); }
  .b-closed{ background: rgba(152,162,182,.12); color: var(--dim); box-shadow: inset 0 0 0 1px var(--line-soft); }
  .b-p0,.b-p1 { background: rgba(255,138,138,.14); color: var(--bad); box-shadow: inset 0 0 0 1px rgba(255,138,138,.22); }
  .b-p2 { background: rgba(252,192,67,.14); color: var(--warn); box-shadow: inset 0 0 0 1px rgba(252,192,67,.22); }
  .b-p3,.b-p4 { background: rgba(152,162,182,.10); color: var(--faint); box-shadow: inset 0 0 0 1px var(--line-soft); }
  .spacer { margin-left: auto; }

  /* ── Forms ────────────────────────────────────────────── */
  label { display: block; font-size: 12px; font-weight: 600; color: var(--dim); margin: 12px 0 5px; }
  label:first-child { margin-top: 0; }
  input, textarea, select {
    width: 100%; background: var(--bg-2); color: var(--txt); -webkit-appearance: none; appearance: none;
    border: 1px solid var(--line); border-radius: var(--radius-sm); padding: 12px 13px;
    font-size: 16px; line-height: 1.4; transition: border-color .15s, box-shadow .15s;
  }
  input:focus, textarea:focus, select:focus {
    outline: none; border-color: var(--tint-strong); box-shadow: 0 0 0 3px rgba(107,155,255,.18);
  }
  input::placeholder, textarea::placeholder { color: var(--faint); }
  textarea { resize: vertical; min-height: var(--tap); }
  select {
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='8' viewBox='0 0 12 8'%3E%3Cpath fill='%2398a2b6' d='M1 1l5 5 5-5'/%3E%3C/svg%3E");
    background-repeat: no-repeat; background-position: right 13px center; padding-right: 34px;
  }
  .grid2 { display: flex; gap: 10px; }
  .grid2 > div { flex: 1; min-width: 0; }
  .btn {
    width: 100%; min-height: var(--tap); padding: 13px; border: 0; border-radius: 12px;
    background: linear-gradient(180deg, var(--tint), var(--tint-strong)); color: var(--tint-ink);
    font-size: 15.5px; font-weight: 720; letter-spacing: .1px; margin-top: 14px;
    box-shadow: 0 1px 0 rgba(255,255,255,.18) inset, 0 4px 14px rgba(60,110,230,.25);
    transition: transform .08s, opacity .15s;
  }
  .btn:active { transform: translateY(1px); }
  .btn.ghost {
    background: var(--panel-2); color: var(--txt);
    box-shadow: inset 0 0 0 1px var(--line);
  }
  .btn:disabled { opacity: .5; }

  /* Collapsible "new" panels */
  details {
    background: var(--panel); border: 1px solid var(--line-soft); border-radius: var(--radius);
    margin-bottom: 6px; overflow: hidden;
  }
  details[open] { border-color: var(--line); }
  details > summary {
    cursor: pointer; list-style: none; min-height: 44px;
    display: flex; align-items: center; gap: 9px; padding: 0 14px;
    color: var(--tint); font-weight: 640; font-size: 14px; user-select: none;
  }
  details > summary::-webkit-details-marker { display: none; }
  details > summary .chev { margin-left: auto; color: var(--faint); transition: transform .2s; font-size: 13px; }
  details[open] > summary .chev { transform: rotate(90deg); }
  details .body { padding: 0 14px 14px; }
  /* Pin the new-issue / dispatch ("compose") control to the top of the scroll
     area so it stays reachable while the list scrolls under it. Sticky is
     relative to <main> (the overflow-y:auto container); the safe-area notch is
     already handled by the sticky <header> above main. */
  details.create { position: sticky; top: 0; z-index: 4; margin: 0 -12px 6px;
    padding: 4px 12px 0; background: var(--bg); }

  /* ── States ───────────────────────────────────────────── */
  .state { text-align: center; color: var(--dim); padding: 38px 18px; }
  .state .emoji { font-size: 26px; opacity: .85; display: block; margin-bottom: 8px; }
  .state .big { font-size: 15px; font-weight: 600; color: var(--txt); }
  .state .small { font-size: 13px; margin-top: 4px; color: var(--faint); }
  .state.err { color: var(--bad); }
  .state.err .big { color: var(--bad); }
  .retry {
    margin-top: 14px; min-height: 40px; padding: 0 18px; border: 0; border-radius: 10px;
    background: var(--panel-2); color: var(--txt); box-shadow: inset 0 0 0 1px var(--line);
    font-weight: 640; font-size: 14px;
  }
  .skel { padding: 13px 14px; margin-bottom: 9px; border-radius: var(--radius);
    background: var(--panel); border: 1px solid var(--line-soft); }
  .skel .bar { height: 11px; border-radius: 6px;
    background: linear-gradient(90deg, var(--panel-2) 25%, var(--panel-hi) 37%, var(--panel-2) 63%);
    background-size: 280% 100%; animation: shimmer 1.3s linear infinite; }
  .skel .bar.w1 { width: 38%; } .skel .bar.w2 { width: 78%; margin-top: 9px; }
  @keyframes shimmer { from { background-position: 200% 0; } to { background-position: -80% 0; } }

  /* ── Install hint (iOS A2HS) ──────────────────────────── */
  .install {
    margin: 8px 2px 4px; padding: 13px 14px; border-radius: var(--radius);
    background: linear-gradient(180deg, rgba(138,180,255,.10), rgba(138,180,255,.03));
    border: 1px solid rgba(138,180,255,.25); display: flex; gap: 11px; align-items: flex-start;
  }
  .install .ic { font-size: 20px; line-height: 1.2; }
  .install .tx { flex: 1; font-size: 13.5px; color: var(--txt); }
  .install .tx b { font-weight: 700; }
  .install .tx .share {
    display: inline-flex; width: 18px; height: 18px; vertical-align: -4px; margin: 0 1px;
    color: var(--tint);
  }
  .install .tx .small { color: var(--dim); font-size: 12.5px; margin-top: 3px; }
  .install .x {
    flex: none; width: 30px; height: 30px; border: 0; border-radius: 8px; background: transparent;
    color: var(--faint); font-size: 17px; margin: -4px -6px 0 0;
  }

  /* ── Chat ─────────────────────────────────────────────── */
  #chat-wrap { display: flex; flex-direction: column; height: 100%; }
  #log { flex: 1; overflow-y: auto; -webkit-overflow-scrolling: touch;
    display: flex; flex-direction: column; gap: 9px; padding: 6px 0 10px; }
  .msg {
    max-width: 88%; padding: 10px 13px; border-radius: 16px; font-size: 15px;
    white-space: pre-wrap; word-break: break-word; line-height: 1.45;
    animation: pop .18s ease;
  }
  @keyframes pop { from { opacity: 0; transform: translateY(3px) scale(.99); } to { opacity: 1; transform: none; } }
  .msg.me {
    align-self: flex-end; color: var(--tint-ink); border-bottom-right-radius: 5px;
    background: linear-gradient(180deg, var(--tint), var(--tint-strong));
  }
  .msg.or {
    align-self: flex-start; background: var(--panel-2); color: var(--txt);
    border: 1px solid var(--line); border-bottom-left-radius: 5px;
  }
  .msg.err { border-color: rgba(255,138,138,.5); color: var(--bad); }
  .msg code { background: rgba(255,255,255,.08); padding: 1px 5px; border-radius: 5px;
    font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; }
  .typing { align-self: flex-start; display: inline-flex; gap: 4px; padding: 12px 14px;
    background: var(--panel-2); border: 1px solid var(--line); border-radius: 16px; border-bottom-left-radius: 5px; }
  .typing i { width: 6px; height: 6px; border-radius: 50%; background: var(--dim);
    animation: blink 1.2s infinite both; }
  .typing i:nth-child(2) { animation-delay: .2s; } .typing i:nth-child(3) { animation-delay: .4s; }
  @keyframes blink { 0%,80%,100% { opacity: .25; } 40% { opacity: 1; } }
  .dock {
    position: sticky; bottom: 0;
    background: linear-gradient(transparent, var(--bg) 24%);
    padding-bottom: calc(var(--sab) + 6px);
  }
  .composer {
    display: flex; gap: 9px; align-items: flex-end; padding: 8px 0 0;
  }
  .attach { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; padding: 6px 0 0; }
  .attach button {
    display: inline-flex; align-items: center; gap: 5px; min-height: 34px;
    padding: 0 12px; border: 0; border-radius: 999px; background: var(--panel);
    color: var(--dim); box-shadow: inset 0 0 0 1px var(--line-soft);
    font-size: 12.5px; font-weight: 600; transition: transform .08s;
  }
  .attach button:active { transform: scale(.96); }
  .attach button:disabled { opacity: .5; }
  .attach button.rec {
    color: var(--bad); background: rgba(255,138,138,.12);
    box-shadow: inset 0 0 0 1px rgba(255,138,138,.4);
  }
  .attach .a-status { flex: 1 1 100%; font-size: 12px; color: var(--faint); }
  .attach .a-status.err { color: var(--bad); }
  .attach .a-status:empty { display: none; }
  /* Preview tray — a chip per picked/recorded file, shown above the composer.
     Each chip previews the media and carries a ✕ to drop it before sending; the
     saved path is appended to the message on send (the Oracle's claude -p reads
     it), so a raw path never clutters the input box. */
  .a-tray { display: flex; flex-wrap: wrap; gap: 8px; padding: 8px 0 0; }
  .a-tray[hidden] { display: none; }
  .a-chip {
    display: flex; align-items: center; gap: 8px; max-width: 100%;
    padding: 5px 8px 5px 5px; border-radius: 12px; background: var(--panel);
    box-shadow: inset 0 0 0 1px var(--line-soft);
  }
  .a-chip.err { box-shadow: inset 0 0 0 1px rgba(255,138,138,.4); }
  .a-chip .thumb {
    width: 36px; height: 36px; flex: none; border-radius: 8px; object-fit: cover;
    background: var(--panel-2); display: grid; place-items: center; font-size: 17px; color: var(--dim);
  }
  .a-chip .info { min-width: 0; display: flex; flex-direction: column; }
  .a-chip .nm { font-size: 12.5px; color: var(--txt); max-width: 150px;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .a-chip .stt { font-size: 11px; color: var(--faint); margin-top: 1px; }
  .a-chip.err .stt { color: var(--bad); }
  .a-chip .rm { flex: none; border: 0; background: transparent; color: var(--dim);
    font-size: 15px; padding: 2px 5px; border-radius: 8px; }
  .a-chip .rm:active { background: var(--panel-2); }
  .composer textarea {
    flex: 1; min-width: 0; min-height: var(--tap); max-height: 130px; height: var(--tap);
    border-radius: 22px; padding: 12px 16px; background: var(--panel);
    /* No manual drag-resize: it leaves a handle poking outside the rounded
       corner on mobile. The input grows to fit its content (see the input
       event handler) up to max-height, then scrolls internally. min-width:0
       lets the flex item shrink so the caret/box never overflows the viewport. */
    resize: none; overflow-y: auto;
    /* Hide the scrollbar: a single resting line (24px line-height + 24px
       padding) is a hair taller than the 46px box, so the gutter would draw a
       stray vertical line down the right edge by the send button. Content still
       scrolls internally once it grows past max-height. */
    scrollbar-width: none;
  }
  .composer textarea::-webkit-scrollbar { width: 0; height: 0; display: none; }
  .composer .send {
    width: var(--tap); height: var(--tap); flex: none; border: 0; border-radius: 50%;
    background: linear-gradient(180deg, var(--tint), var(--tint-strong)); color: var(--tint-ink);
    font-size: 18px; font-weight: 800; display: grid; place-items: center;
    box-shadow: 0 3px 12px rgba(60,110,230,.3); transition: transform .08s, opacity .15s;
  }
  .composer .send:active { transform: scale(.94); }
  .composer .send:disabled { opacity: .45; }
  .chat-empty { margin: auto; text-align: center; padding: 28px 18px; color: var(--dim); }
  .chat-empty .emoji { font-size: 28px; display: block; margin-bottom: 10px; }
  .chat-empty .big { color: var(--txt); font-weight: 600; font-size: 16px; }
  .chat-empty .small { font-size: 13.5px; margin-top: 6px; line-height: 1.5; }
  /* Chat session bar + past-chats list. The head is pinned to the top of the
     scroll area (sticky relative to <main>) so the ☰ Chats / ＋ New switcher —
     and the past-chats list it toggles — stay reachable while the log scrolls
     under it. Negative side margins + matching padding let the solid backdrop
     span main's full width so messages don't peek past its edges. The notch is
     already handled by the sticky <header> above main. */
  .chat-head {
    position: sticky; top: 0; z-index: 5;
    margin: 0 -12px; padding: 0 12px; background: var(--bg);
  }
  #chat-bar { display: flex; align-items: center; gap: 8px; padding: 4px 0 6px; }
  #c-title { flex: 1; min-width: 0; font-size: 13px; font-weight: 600; color: var(--faint);
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .chat-pill {
    flex: none; display: inline-flex; align-items: center; gap: 5px;
    padding: 0 15px; min-height: 40px;
    border: 0; border-radius: 999px; background: var(--panel); color: var(--dim);
    box-shadow: inset 0 0 0 1px var(--line-soft); font-size: 13.5px; font-weight: 640;
  }
  .chat-pill:active { transform: scale(.96); }
  #chat-sessions { display: flex; flex-direction: column; gap: 6px; padding: 2px 0 8px;
    max-height: 46%; overflow-y: auto; -webkit-overflow-scrolling: touch; }
  .chat-srow {
    display: flex; align-items: center; gap: 8px; padding: 9px 12px; border-radius: 12px;
    background: var(--panel); box-shadow: inset 0 0 0 1px var(--line-soft); cursor: pointer;
  }
  .chat-srow.active { box-shadow: inset 0 0 0 1px var(--tint); }
  .chat-srow .st { flex: 1; min-width: 0; }
  .chat-srow .ct { font-size: 14px; color: var(--txt); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .chat-srow .ca { font-size: 11.5px; color: var(--dim); margin-top: 1px; }
  .chat-srow .cx { flex: none; border: 0; background: transparent; color: var(--dim);
    font-size: 15px; padding: 4px 6px; border-radius: 8px; }
  .chat-srow .cx:active { background: var(--panel-2); }

  /* ── Session inline reply ─────────────────────────────── */
  .sess { cursor: pointer; }
  .sess .reply-hint { margin-top: 9px; font-size: 12px; font-weight: 600; color: var(--tint); }
  .sreply { display: flex; gap: 8px; align-items: flex-end; margin-top: 10px; cursor: auto; }
  .sreply textarea {
    flex: 1; min-height: 40px; max-height: 120px; height: 40px;
    border-radius: 12px; padding: 9px 13px; background: var(--bg-2);
  }
  .sreply .sreply-send {
    width: 40px; height: 40px; flex: none; border: 0; border-radius: 50%;
    background: linear-gradient(180deg, var(--tint), var(--tint-strong)); color: var(--tint-ink);
    font-size: 16px; font-weight: 800; display: grid; place-items: center;
    box-shadow: 0 3px 12px rgba(60,110,230,.3); transition: transform .08s, opacity .15s;
  }
  .sreply .sreply-send:active { transform: scale(.94); }
  .sreply .sreply-send:disabled { opacity: .45; }
  .sdel {
    flex: none; border: 0; background: transparent; color: var(--faint);
    font-size: 15px; line-height: 1; padding: 5px 7px; margin: -3px -5px -3px 0;
    border-radius: 8px;
  }
  .sdel:active { background: var(--panel-2); color: var(--bad); }
  .sdel.armed { background: var(--bad); color: #fff; font-size: 12px; font-weight: 600; padding: 5px 9px; }

  /* ── Live session view ────────────────────────────────── */
  .slive {
    flex: none; min-height: 30px; padding: 0 12px; border: 0; border-radius: 999px;
    background: rgba(138,180,255,.14); color: var(--tint);
    box-shadow: inset 0 0 0 1px rgba(138,180,255,.22);
    font-size: 12.5px; font-weight: 640; transition: transform .08s;
  }
  .slive:active { transform: scale(.96); }
  .live-back {
    position: fixed; inset: 0; z-index: 40; display: flex; flex-direction: column;
    background: var(--bg);
    padding: calc(var(--sat) + 10px) calc(var(--sar) + 10px) calc(var(--sab) + 8px) calc(var(--sal) + 10px);
  }
  .live-back[hidden] { display: none; }
  .live-head { display: flex; align-items: center; gap: 10px; padding: 2px 2px 10px; }
  .live-head .lt { flex: 1; min-width: 0; }
  #live-title { font-size: 14.5px; font-weight: 640; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .lst {
    font: 600 10.5px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
    letter-spacing: .1em; text-transform: uppercase; color: var(--faint); margin-top: 3px;
  }
  .live-head .lx {
    flex: none; width: 34px; height: 34px; border: 0; border-radius: 999px;
    background: var(--panel); color: var(--dim); box-shadow: inset 0 0 0 1px var(--line-soft);
    font-size: 15px;
  }
  .live-head .lx:active { background: var(--panel-2); color: var(--txt); }
  /* Panel colors must match screen-html.ts DEFAULT_FG / DEFAULT_BG. */
  .live-screen {
    flex: 1; min-height: 0; overflow: auto; -webkit-overflow-scrolling: touch;
    background: #0b0e14; border: 1px solid var(--line); border-radius: var(--radius-sm);
    padding: 8px;
  }
  .live-screen pre {
    margin: 0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 11px; line-height: 1.35; color: #d6dbe5;
  }
  .live-screen .lrow { white-space: pre; min-height: 1.35em; }
  .live-foot { display: flex; gap: 8px; align-items: flex-end; padding: 8px 0 0; }
  .live-foot textarea {
    flex: 1; min-width: 0; min-height: 40px; max-height: 120px; height: 40px;
    border-radius: 12px; padding: 9px 13px; background: var(--panel);
    resize: none; overflow-y: auto; scrollbar-width: none;
  }
  .live-foot textarea::-webkit-scrollbar { width: 0; height: 0; display: none; }
  .live-foot .lq, .live-foot .ls {
    width: 40px; height: 40px; flex: none; border: 0; border-radius: 50%;
    display: grid; place-items: center; font-size: 16px;
    transition: transform .08s, opacity .15s;
  }
  .live-foot .lq { background: var(--panel-2); color: var(--dim); box-shadow: inset 0 0 0 1px var(--line); }
  .live-foot .ls {
    background: linear-gradient(180deg, var(--tint), var(--tint-strong)); color: var(--tint-ink);
    font-weight: 800; box-shadow: 0 3px 12px rgba(60,110,230,.3);
  }
  .live-foot .lq:active, .live-foot .ls:active { transform: scale(.94); }
  .live-foot button:disabled { opacity: .45; }

  /* ── Settings (keyboard shortcuts) ── */
  .gear {
    flex: none; margin-left: 8px; width: 34px; height: 34px; border-radius: 999px;
    display: grid; place-items: center; font-size: 16px; cursor: pointer;
    color: var(--dim); background: var(--panel); border: none;
    box-shadow: inset 0 0 0 1px var(--line-soft);
  }
  .gear:active { background: var(--panel-2); color: var(--txt); }
  .modal-back {
    position: fixed; inset: 0; z-index: 50; display: grid; place-items: center;
    padding: 18px; background: rgba(5,7,12,.6); backdrop-filter: blur(3px);
  }
  .modal-back[hidden] { display: none; }
  .modal {
    width: 100%; max-width: 460px; max-height: 84vh; overflow: auto;
    background: var(--panel); border: 1px solid var(--line); border-radius: var(--radius);
    box-shadow: 0 18px 50px rgba(0,0,0,.5); padding: 16px;
  }
  .modal h2 { font-size: 15px; margin: 0 0 2px; }
  .modal .hint { color: var(--dim); font-size: 12px; margin: 0 0 14px; }
  .sc-row {
    display: flex; align-items: center; gap: 8px; flex-wrap: wrap;
    padding: 11px 0; border-top: 1px solid var(--line-soft);
  }
  .sc-row .sc-name { flex: 1 1 100%; font-size: 13.5px; }
  .sc-row .sc-name small { color: var(--faint); font-weight: 400; }
  .sc-chip {
    min-width: 34px; height: 32px; padding: 0 8px; border-radius: var(--radius-sm);
    font: 600 13px/1 ui-monospace, Menlo, monospace; cursor: pointer; color: var(--dim);
    background: var(--panel-2); border: none; box-shadow: inset 0 0 0 1px var(--line-soft);
  }
  .sc-chip.on { color: var(--tint-ink); background: var(--tint); box-shadow: none; }
  .sc-key {
    width: 52px; height: 32px; text-align: center; border-radius: var(--radius-sm);
    background: var(--panel-2); color: var(--txt); border: none;
    box-shadow: inset 0 0 0 1px var(--line-soft); font: 600 13px/1 ui-monospace, Menlo, monospace;
  }
  .sc-reset { margin-left: auto; background: none; border: none; color: var(--faint); cursor: pointer; font-size: 16px; }
  .sc-static { color: var(--faint); font: 600 12px/1 ui-monospace, Menlo, monospace; }
  .modal-foot { display: flex; gap: 8px; margin-top: 16px; }
  .modal-foot .btn-ghost { background: none; box-shadow: inset 0 0 0 1px var(--line); color: var(--dim); }

  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after { animation-duration: .001ms !important; transition: none !important; }
  }
</style>
</head>
<body>
  <header>
    <span class="mark">✦</span>
    <span class="brand"><h1>Oracle</h1><span class="sub">Console</span></span>
    <span id="conn" class="conn"><span class="dot"></span><span id="conn-txt">link…</span></span>
    <button id="settings-btn" class="gear" aria-label="Keyboard shortcuts">⚙</button>
  </header>

  <nav>
    <button data-tab="issues" class="active">Issues</button>
    <button data-tab="sessions">Sessions</button>
    <button data-tab="chat">Chat</button>
  </nav>

  <main>
    <!-- ── Issues ─────────────────────────────────────── -->
    <section id="issues" class="tab active">
      <div id="install-hint"></div>

      <details class="create">
        <summary>＋ New global issue<span class="chev">›</span></summary>
        <div class="body">
          <label>Title</label>
          <input id="i-title" placeholder="Short title" autocapitalize="sentences" />
          <label>Description</label>
          <textarea id="i-desc" placeholder="Context (optional)"></textarea>
          <div class="grid2">
            <div><label>Type</label>
              <select id="i-type"><option>task</option><option>feature</option><option>bug</option><option>chore</option><option>epic</option></select></div>
            <div><label>Priority</label>
              <select id="i-prio"><option value="0">P0</option><option value="1">P1</option><option value="2" selected>P2</option><option value="3">P3</option><option value="4">P4</option></select></div>
          </div>
          <button class="btn" id="i-create">Create issue</button>
        </div>
      </details>

      <div class="sec-head">Global board <span id="i-count" class="count" hidden></span></div>
      <div id="issues-list"></div>
    </section>

    <!-- ── Sessions ───────────────────────────────────── -->
    <section id="sessions" class="tab">
      <details class="create">
        <summary>➤ Dispatch an agent<span class="chev">›</span></summary>
        <div class="body">
          <label>Project path</label>
          <input id="d-project" placeholder="/Users/you/repo" autocapitalize="none" autocorrect="off" spellcheck="false" />
          <label>Prompt</label>
          <textarea id="d-prompt" placeholder="What should the agent do?"></textarea>
          <div class="grid2">
            <div><label>Provider</label>
              <select id="d-prov"><option>claude</option><option>codex</option></select></div>
            <div><label>Worktree</label>
              <select id="d-wt"><option value="false">No</option><option value="true">Yes</option></select></div>
          </div>
          <button class="btn" id="d-go">Dispatch agent</button>
        </div>
      </details>

      <div class="sec-head">Running &amp; recent <span id="s-count" class="count" hidden></span></div>
      <div id="sessions-list"></div>
    </section>

    <!-- ── Chat ───────────────────────────────────────── -->
    <section id="chat" class="tab">
      <div id="chat-wrap">
        <div class="chat-head">
          <div id="chat-bar">
            <button id="c-history" class="chat-pill" aria-label="Past chats">☰ Chats</button>
            <span id="c-title">New chat</span>
            <button id="c-new" class="chat-pill">＋ New</button>
          </div>
          <div id="chat-sessions" hidden></div>
        </div>
        <div id="log"></div>
        <div class="dock">
          <div class="attach">
            <button id="a-photo" type="button">📷 Photo</button>
            <button id="a-rec" type="button" hidden>🎤 Record</button>
            <button id="a-file" type="button">📎 Attach</button>
            <span id="a-status" class="a-status"></span>
          </div>
          <div id="a-tray" class="a-tray" hidden></div>
          <div class="composer">
            <textarea id="c-input" placeholder="Ask the Oracle…" rows="1"></textarea>
            <button id="c-send" class="send" aria-label="Send">➤</button>
          </div>
        </div>
        <input id="a-photo-input" type="file" accept="image/*" capture="environment" hidden />
        <input id="a-file-input" type="file" accept="image/*,audio/*" hidden />
      </div>
    </section>
  </main>

  <!-- ── Live session view (read-only screen + quick reply) ── -->
  <div id="live-view" class="live-back" hidden>
    <div class="live-head">
      <div class="lt">
        <div id="live-title">Session</div>
        <div id="live-status" class="lst">connecting…</div>
      </div>
      <button id="live-close" class="lx" aria-label="Close live view">✕</button>
    </div>
    <div id="live-screen" class="live-screen"><pre id="live-pre"></pre></div>
    <div class="live-foot">
      <textarea id="live-in" placeholder="Reply into this session…" rows="1"></textarea>
      <button id="live-queue" class="lq" aria-label="Queue for next idle" title="Queue for next idle">⏳</button>
      <button id="live-send" class="ls" aria-label="Send reply">➤</button>
    </div>
  </div>

  <!-- ── Settings: keyboard shortcuts ───────────────────── -->
  <div id="settings-modal" class="modal-back" hidden>
    <div class="modal" role="dialog" aria-label="Keyboard shortcuts">
      <h2>Keyboard shortcuts</h2>
      <p class="hint">Edit the combo, then it applies right away. Some browsers reserve ⌘N/Ctrl+N for a new window — if it doesn't fire, rebind to a free combo.</p>
      <div id="sc-list"></div>
      <div class="modal-foot">
        <button class="btn btn-ghost" id="sc-reset-all">Reset all</button>
        <button class="btn" id="sc-close">Done</button>
      </div>
    </div>
  </div>

<script>
const $ = (s) => document.querySelector(s);
const sleep = (ms) => new Promise((res) => setTimeout(res, ms));
// fetch with a small backoff retry for *network* failures only — a phone lock or
// backgrounded tab rejects fetch with a TypeError ("Failed to fetch") that resolves
// itself once the link is back. HTTP error responses (4xx/5xx) are never retried, and
// only idempotent GETs retry — a request with a method (POST/DELETE) stays one-shot so
// we never resubmit a mutation. Mirrors apps/web's fetchGetWithRetry.
const api = async (path, opts) => {
  const idempotent = !opts || !opts.method || opts.method === "GET";
  const attempts = idempotent ? 3 : 1;
  let lastErr;
  for (let i = 0; i < attempts; i++) {
    let r;
    try {
      r = await fetch(path, { headers: { "content-type": "application/json" }, ...opts });
    } catch (err) {
      lastErr = err; // network error — fetch only rejects for these, not for 4xx/5xx
      if (i < attempts - 1) { await sleep(Math.min(300 * 2 ** i, 2000)); continue; }
      throw err;
    }
    if (!r.ok) throw new Error((await r.text()) || ("HTTP " + r.status));
    return r.json();
  }
  throw lastErr;
};
function esc(s){ return String(s).replace(/[&<>"]/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])); }

// Connection indicator — flips on every successful/failed API round-trip.
let connState = null;
function setConn(ok){
  if (connState === ok) return; connState = ok;
  const el = $("#conn"); el.className = "conn " + (ok ? "ok" : "bad");
  $("#conn-txt").textContent = ok ? "live" : "offline";
}

// Shared state-block renderers so loading/empty/error feel consistent.
const skeletons = (n) => Array.from({length:n}, () =>
  '<div class="skel"><div class="bar w1"></div><div class="bar w2"></div></div>').join("");
const emptyState = (emoji, big, small) =>
  '<div class="state"><span class="emoji">'+emoji+'</span><div class="big">'+big+'</div>'
  + (small ? '<div class="small">'+small+'</div>' : '') + '</div>';
const errState = (msg, retry) =>
  '<div class="state err"><span class="emoji">⚠</span><div class="big">Couldn\\'t reach the Oracle</div>'
  + '<div class="small">'+esc(msg)+'</div>'
  + (retry ? '<button class="retry" data-retry="'+retry+'">Try again</button>' : '') + '</div>';
function setCount(sel, n){ const el = $(sel); el.hidden = false; el.textContent = n; }

// ── Tabs ──────────────────────────────────────────────────
document.querySelectorAll("nav button").forEach((b) => b.onclick = () => {
  document.querySelectorAll("nav button").forEach((x) => x.classList.toggle("active", x === b));
  document.querySelectorAll(".tab").forEach((t) => t.classList.toggle("active", t.id === b.dataset.tab));
  if (b.dataset.tab === "issues") loadIssues();
  if (b.dataset.tab === "sessions") loadSessions();
  if (b.dataset.tab === "chat") $("#c-input").focus();
});

// Retry buttons inside error states.
document.addEventListener("click", (e) => {
  const r = e.target.closest && e.target.closest("[data-retry]");
  if (!r) return;
  if (r.dataset.retry === "issues") loadIssues();
  if (r.dataset.retry === "sessions") loadSessions();
});

// ── Issues ────────────────────────────────────────────────
function prioBadge(p){ return '<span class="badge b-p'+p+'">P'+p+'</span>'; }
function statusBadge(s){ const c = s==="closed"?"b-closed":"b-open"; return '<span class="badge '+c+'">'+esc(s)+'</span>'; }
let issuesLoaded = false;
async function loadIssues(){
  const el = $("#issues-list");
  if (!issuesLoaded) el.innerHTML = skeletons(4);
  try {
    const items = await api("/api/issues"); setConn(true); issuesLoaded = true;
    setCount("#i-count", items.length);
    if (!items.length) { el.innerHTML = emptyState("◌", "No global issues", "Cross-project work shows up here. Add one above."); return; }
    el.innerHTML = items.map((i) =>
      '<div class="card item"><div class="row"><span class="id">'+esc(i.id)+'</span>'
      + prioBadge(i.priority) + statusBadge(i.status)
      + (i.ready?'<span class="badge b-ready">ready</span>':'')
      + '</div><div class="title">'+esc(i.title)+'</div>'
      + '<div class="meta"><span>'+esc(i.issueType||"")+'</span>'
      + (i.parent?'<span>↑ '+esc(i.parent)+'</span>':'')+'</div></div>').join("");
  } catch(e){ setConn(false); el.innerHTML = errState(e.message, "issues"); }
}
$("#i-create").onclick = async () => {
  const title = $("#i-title").value.trim();
  if (!title) { $("#i-title").focus(); return; }
  const btn = $("#i-create"); btn.disabled = true; btn.textContent = "Creating…";
  try {
    await api("/api/issues", { method:"POST", body: JSON.stringify({
      title, description: $("#i-desc").value.trim() || undefined,
      type: $("#i-type").value, priority: Number($("#i-prio").value) }) });
    $("#i-title").value = $("#i-desc").value = "";
    const det = $("#issues details"); if (det) det.open = false;
    await loadIssues();
  } catch(e){ alert("Couldn't create the issue: "+e.message); }
  btn.disabled = false; btn.textContent = "Create issue";
};

// ── Sessions ──────────────────────────────────────────────
let sessionsLoaded = false;
async function loadSessions(){
  const el = $("#sessions-list");
  if (!sessionsLoaded) el.innerHTML = skeletons(3);
  try {
    const data = await api("/api/sessions"); setConn(true); sessionsLoaded = true;
    const list = Array.isArray(data) ? data : (data.sessions || []);
    setCount("#s-count", list.length);
    if (!list.length) { el.innerHTML = emptyState("⊘", "No sessions", "Dispatch an agent above and it'll appear here."); return; }
    el.innerHTML = list.map((s) => {
      const st = (s.status||"").toLowerCase();
      const live = st && st !== "exited" && st !== "closed" && st !== "done";
      const id = esc(s.id || s.cliSessionId || "");
      const del = id ? '<button class="sdel" data-del="'+id+'" aria-label="Delete session">✕</button>' : '';
      const liveBtn = (live && id)
        ? '<button class="slive" data-live="'+id+'" data-title="'+esc(s.title||"untitled")+'">Live</button>' : '';
      const head = '<div class="row"><span class="title">'+esc(s.title||"untitled")+'</span>'
      + '<span class="badge b-open spacer">'+esc(s.provider||"agent")+'</span>'+liveBtn+del+'</div>'
      + '<div class="meta"><span class="mono">'+esc(s.cwd||"")+'</span>'
      + (s.status?'<span class="badge '+(live?"b-ready":"b-closed")+'">'+esc(s.status)+'</span>':'')+'</div>';
      if (!live || !id) return '<div class="card item">'+head+'</div>';
      return '<div class="card item sess" data-id="'+id+'" data-cwd="'+esc(s.cwd||"")+'" data-prov="'+esc(s.provider||"")+'">'+head
      + '<div class="reply-hint">Tap to reply →</div>'
      + '<div class="sreply" hidden>'
      + '<textarea class="sreply-in" placeholder="Reply to this agent…" rows="1"></textarea>'
      + '<button class="sreply-send" aria-label="Send reply">➤</button></div></div>';
    }).join("");
    // A ?session=<id> deep-link may have asked us to open a specific session's reply box.
    if (pendingReplyId) { openSessionReply(pendingReplyId); pendingReplyId = null; }
  } catch(e){ setConn(false); el.innerHTML = errState(e.message, "sessions"); }
}
$("#d-go").onclick = async () => {
  const project = $("#d-project").value.trim(), prompt = $("#d-prompt").value.trim();
  if (!project || !prompt) { alert("Project path and prompt are both required."); return; }
  const btn = $("#d-go"); btn.disabled = true; btn.textContent = "Dispatching…";
  try {
    await api("/api/dispatch", { method:"POST", body: JSON.stringify({
      project, prompt, provider: $("#d-prov").value, worktree: $("#d-wt").value === "true" }) });
    $("#d-prompt").value = "";
    btn.textContent = "Dispatched ✓";
    setTimeout(() => { btn.textContent = "Dispatch agent"; btn.disabled = false; }, 1400);
    await loadSessions();
  } catch(e){ alert("Dispatch failed: "+e.message); btn.textContent = "Dispatch agent"; btn.disabled = false; }
};

// ── Reply into a live session ─────────────────────────────
// Tap a running session card to reveal an inline reply box; the text is delivered
// into that session's pty (POST /api/reply). A ?session=<id> deep-link opens the
// matching card's box once the list renders.
let pendingReplyId = null;
function openSessionReply(id){
  const sel = (window.CSS && CSS.escape) ? CSS.escape(id) : id;
  const card = document.querySelector('#sessions-list .sess[data-id="' + sel + '"]');
  if (!card) return;
  const box = card.querySelector(".sreply"), hint = card.querySelector(".reply-hint");
  if (!box) return;
  box.hidden = false; if (hint) hint.hidden = true;
  const ta = box.querySelector("textarea"); if (ta) ta.focus();
  card.scrollIntoView({ block: "center" });
}
async function sendReply(card){
  if (!card) return;
  const id = card.dataset.id, ta = card.querySelector(".sreply-in"), btn = card.querySelector(".sreply-send");
  const text = ta ? ta.value.trim() : ""; if (!text) { if (ta) ta.focus(); return; }
  if (btn) btn.disabled = true;
  try {
    await api("/api/reply", { method:"POST", body: JSON.stringify({ sessionId: id, text }) }); setConn(true);
    if (ta) { ta.value = ""; ta.style.height = ""; }
    card.querySelector(".sreply").hidden = true;
    const hint = card.querySelector(".reply-hint"); if (hint) { hint.hidden = false; hint.textContent = "Sent ✓ — tap to reply again"; }
  } catch(e){ setConn(false); alert("Couldn't send the reply: " + e.message); }
  if (btn) btn.disabled = false;
}
// Permanently delete a session (kills its pty + removes any auto-created worktree on
// the Mac, via the native app). Destructive, so confirm first — but via an inline
// two-tap arm rather than window.confirm(), which is a silent no-op in an installed
// iOS standalone PWA (the home-screen console) and so swallowed the delete entirely.
// First tap arms the ✕ (shows "Delete?"), a second tap within 3s actually deletes.
async function deleteSessionCard(btn){
  const id = btn && btn.dataset.del;
  if (!id) return;
  if (!btn.classList.contains("armed")){
    btn.classList.add("armed"); btn.textContent = "Delete?";
    clearTimeout(btn._disarm);
    btn._disarm = setTimeout(() => { btn.classList.remove("armed"); btn.textContent = "✕"; }, 3000);
    return;
  }
  clearTimeout(btn._disarm); btn.disabled = true;
  try {
    await api("/api/sessions/delete", { method:"POST", body: JSON.stringify({ id }) }); setConn(true);
    await loadSessions();
  } catch(e){
    setConn(false); btn.disabled = false; btn.classList.remove("armed"); btn.textContent = "✕";
    alert("Couldn't delete the session: " + e.message);
  }
}
$("#sessions-list").addEventListener("click", (e) => {
  const delBtn = e.target.closest && e.target.closest("[data-del]");
  if (delBtn) { e.stopPropagation(); deleteSessionCard(delBtn); return; }
  const liveBtn = e.target.closest && e.target.closest("[data-live]");
  if (liveBtn) { e.stopPropagation(); openLiveView(liveBtn.dataset.live, liveBtn.dataset.title); return; }
  const sendBtn = e.target.closest && e.target.closest(".sreply-send");
  if (sendBtn) { sendReply(sendBtn.closest(".sess")); return; }
  if (e.target.closest && e.target.closest(".sreply")) return; // typing — don't toggle
  const card = e.target.closest && e.target.closest(".sess[data-id]");
  if (!card) return;
  const box = card.querySelector(".sreply"), hint = card.querySelector(".reply-hint");
  if (!box) return;
  const show = box.hidden; box.hidden = !show; if (hint) hint.hidden = show;
  if (show) { const ta = box.querySelector("textarea"); if (ta) ta.focus(); }
});
$("#sessions-list").addEventListener("input", (e) => {
  const t = e.target;
  if (t && t.classList && t.classList.contains("sreply-in")) {
    t.style.height = "auto"; t.style.height = Math.min(t.scrollHeight, 120) + "px";
  }
});
$("#sessions-list").addEventListener("keydown", (e) => {
  const t = e.target;
  if (t && t.classList && t.classList.contains("sreply-in") && e.key === "Enter" && !e.shiftKey) {
    e.preventDefault(); sendReply(t.closest(".sess"));
  }
});

// ── Live session view ─────────────────────────────────────
// Read-only mirror of a running session's screen, streamed as SSE from the
// sidecar (GET /api/sessions/<id>/screen). Rows arrive as pre-rendered HTML —
// a full grid first, then only changed rows — and are patched in place. The
// view never sends resize (EventSource is receive-only), so watching from the
// phone can't disturb the Mac's terminal grid. The footer reuses /api/reply
// (deliver now) and /api/queue (hold for next idle).
let liveEs = null, liveGrid = { cols: 0, rows: 0, els: [] }, liveStatusBase = "";
function setLiveStatus(t){ liveStatusBase = t; $("#live-status").textContent = t; }
function flashLiveStatus(t){
  $("#live-status").textContent = t;
  setTimeout(() => { $("#live-status").textContent = liveStatusBase; }, 1600);
}
function openLiveView(id, title){
  closeLiveView();
  $("#live-view").dataset.id = id;
  $("#live-title").textContent = title || id;
  $("#live-pre").innerHTML = "";
  liveGrid = { cols: 0, rows: 0, els: [] };
  $("#live-view").hidden = false;
  setLiveStatus("connecting…");
  liveEs = new EventSource("/api/sessions/" + encodeURIComponent(id) + "/screen");
  liveEs.addEventListener("screen", (e) => {
    let p; try { p = JSON.parse(e.data); } catch(_){ return; }
    applyScreenPatch(p);
    setConn(true);
    setLiveStatus("live · " + p.cols + "×" + p.rows);
  });
  // EventSource reconnects on its own; the server re-primes with a full grid.
  liveEs.onerror = () => setLiveStatus("reconnecting…");
}
function closeLiveView(){
  if (liveEs){ liveEs.close(); liveEs = null; }
  $("#live-view").hidden = true;
}
function applyScreenPatch(p){
  const pre = $("#live-pre");
  if (p.reset || p.rows !== liveGrid.rows || p.cols !== liveGrid.cols){
    pre.innerHTML = "";
    liveGrid = { cols: p.cols, rows: p.rows, els: [] };
    for (let r = 0; r < p.rows; r++){
      const d = document.createElement("div"); d.className = "lrow";
      pre.appendChild(d); liveGrid.els.push(d);
    }
    fitLiveFont();
  }
  for (const l of p.lines){ const el = liveGrid.els[l.row]; if (el) el.innerHTML = l.html || ""; }
}
// Scale the monospace font so the pty's own column count fits the phone width
// (within limits); beyond that the panel scrolls. ~0.6em per monospace cell.
function fitLiveFont(){
  if (!liveGrid.cols) return;
  const w = $("#live-screen").clientWidth - 16;
  const size = Math.max(6.5, Math.min(13, w / (liveGrid.cols * 0.602)));
  $("#live-pre").style.fontSize = size.toFixed(2) + "px";
}
window.addEventListener("resize", fitLiveFont);
async function liveDeliver(queue){
  const id = $("#live-view").dataset.id;
  const ta = $("#live-in"); const text = ta.value.trim();
  if (!id || !text) { ta.focus(); return; }
  const sb = $("#live-send"), qb = $("#live-queue");
  sb.disabled = qb.disabled = true;
  try {
    const path = queue ? "/api/queue" : "/api/reply";
    const body = queue ? { sessionId: id, messages: [text] } : { sessionId: id, text };
    await api(path, { method: "POST", body: JSON.stringify(body) }); setConn(true);
    ta.value = ""; ta.style.height = "";
    flashLiveStatus(queue ? "queued ✓" : "sent ✓");
  } catch(e){ setConn(false); alert("Couldn't deliver: " + e.message); }
  sb.disabled = qb.disabled = false;
}
$("#live-close").onclick = closeLiveView;
$("#live-send").onclick = () => liveDeliver(false);
$("#live-queue").onclick = () => liveDeliver(true);
$("#live-in").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); liveDeliver(false); }
});
$("#live-in").addEventListener("input", (e) => {
  const t = e.target; t.style.height = "auto"; t.style.height = Math.min(t.scrollHeight, 120) + "px";
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !$("#live-view").hidden) closeLiveView();
});

// ── Keyboard shortcuts (juancode-oe4) ─────────────────────
// Editable, localStorage-backed. Each binding is { mod, shift, alt, key } where
// mod means Ctrl OR Cmd (so one combo works on every platform). Only newChat
// is rebindable here; the in-textarea Enter/Shift+Enter behaviour is shown for
// reference. New chat mirrors the native Cmd-N: start a fresh Oracle conversation.
const SC_KEY = "oracle-shortcuts";
const SC_DEFAULTS = { newChat: { mod: true, shift: false, alt: false, key: "n" } };
const SC_LABELS = { newChat: "New Oracle chat" };
function loadShortcuts(){
  try {
    const raw = localStorage.getItem(SC_KEY);
    if (raw) return Object.assign({}, SC_DEFAULTS, JSON.parse(raw));
  } catch(_){}
  return JSON.parse(JSON.stringify(SC_DEFAULTS));
}
let shortcuts = loadShortcuts();
function saveShortcuts(){ try { localStorage.setItem(SC_KEY, JSON.stringify(shortcuts)); } catch(_){} }
function scDisplay(b){
  if (!b || !b.key) return "—";
  let s = "";
  if (b.mod) s += "⌘/Ctrl+";
  if (b.alt) s += "⌥+";
  if (b.shift) s += "⇧+";
  return s + (b.key === " " ? "Space" : b.key.toUpperCase());
}
function scMatch(b, e){
  if (!b || !b.key) return false;
  const modOk = b.mod ? (e.ctrlKey || e.metaKey) : (!e.ctrlKey && !e.metaKey);
  const key = (e.key || "").toLowerCase();
  return modOk && e.shiftKey === !!b.shift && e.altKey === !!b.alt && key === b.key.toLowerCase();
}

// Cmd/Ctrl+N: surface the Chat tab and start a fresh Oracle conversation.
// startNewChat() is hoisted (declared later); it clears currentSessionId, resets
// the log, and focuses the input.
function newOracleChat(){
  const chatTab = document.querySelector('nav button[data-tab="chat"]');
  if (chatTab) chatTab.click();
  startNewChat();
}

window.addEventListener("keydown", (e) => {
  if (document.getElementById("settings-modal").hidden === false) return; // editing combos
  if (scMatch(shortcuts.newChat, e)) { e.preventDefault(); newOracleChat(); }
});

// ── Settings modal ────────────────────────────────────────
function renderShortcuts(){
  const mods = [["mod","⌘/Ctrl"],["shift","⇧"],["alt","⌥"]];
  const editable = Object.keys(SC_DEFAULTS).map((id) => {
    const b = shortcuts[id];
    const chips = mods.map(([k,sym]) =>
      '<button class="sc-chip'+(b[k]?" on":"")+'" data-sc="'+id+'" data-mod="'+k+'">'+sym+'</button>').join("");
    return '<div class="sc-row"><div class="sc-name">'+esc(SC_LABELS[id])+'</div>'
      + chips
      + '<input class="sc-key" data-sc="'+id+'" data-key="1" maxlength="5" value="'+esc(b.key === " " ? "space" : b.key)+'" />'
      + '<button class="sc-reset" data-sc="'+id+'" data-reset="1" aria-label="Reset">↺</button></div>';
  }).join("");
  const fixed = '<div class="sc-row"><div class="sc-name">Send reply / message <small>in a text box</small></div>'
    + '<span class="sc-static">Enter · ⇧Enter = newline</span></div>';
  $("#sc-list").innerHTML = editable + fixed;
}
function openSettings(){ renderShortcuts(); $("#settings-modal").hidden = false; }
function closeSettings(){ $("#settings-modal").hidden = true; }
$("#settings-btn").onclick = openSettings;
$("#sc-close").onclick = closeSettings;
$("#sc-reset-all").onclick = () => { shortcuts = JSON.parse(JSON.stringify(SC_DEFAULTS)); saveShortcuts(); renderShortcuts(); };
$("#settings-modal").addEventListener("click", (e) => { if (e.target.id === "settings-modal") closeSettings(); });
$("#sc-list").addEventListener("click", (e) => {
  const chip = e.target.closest && e.target.closest(".sc-chip");
  if (chip) { const id = chip.dataset.sc, m = chip.dataset.mod; shortcuts[id][m] = !shortcuts[id][m]; saveShortcuts(); renderShortcuts(); return; }
  const reset = e.target.closest && e.target.closest("[data-reset]");
  if (reset) { const id = reset.dataset.sc; shortcuts[id] = JSON.parse(JSON.stringify(SC_DEFAULTS[id])); saveShortcuts(); renderShortcuts(); }
});
$("#sc-list").addEventListener("change", (e) => {
  const inp = e.target.closest && e.target.closest("[data-key]");
  if (!inp) return;
  const v = inp.value.trim().toLowerCase();
  shortcuts[inp.dataset.sc].key = (v === "space" || v === " ") ? " " : (v.slice(-1) || "");
  saveShortcuts(); renderShortcuts();
});
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !$("#settings-modal").hidden) closeSettings(); });

// ── Chat ──────────────────────────────────────────────────
// Minimal, XSS-safe markdown: escape first, then **bold**, \`code\`, bullets.
function mdLite(s){ return esc(s)
  .replace(/\\*\\*([^*]+)\\*\\*/g, "<b>$1</b>")
  .replace(/\`([^\`]+)\`/g, "<code>$1</code>")
  .replace(/^[-*] /gm, "• "); }
// The claude session id the current thread resumes (null = a fresh chat). We persist
// only the session record server-side — the transcript isn't kept — so switching to a
// past chat starts with an empty log but continues its context on the next message.
let currentSessionId = null;
let currentChatTitle = "";
// Persist the active chat across page reloads. The session list + transcript
// continuity already live server-side (oracle-chat-sessions.json + claude --resume);
// the browser only needs to remember WHICH session it was in, since currentSessionId
// is in-memory and resets to null on reload — making the conversation look lost.
const ACTIVE_CHAT_KEY = "oracle-active-chat";
function saveActiveChat(){
  try {
    if (currentSessionId) localStorage.setItem(ACTIVE_CHAT_KEY, JSON.stringify({ id: currentSessionId, title: currentChatTitle }));
    else localStorage.removeItem(ACTIVE_CHAT_KEY);
  } catch (_) { /* private mode / quota — restore is best-effort */ }
}
function readActiveChat(){
  try {
    const raw = localStorage.getItem(ACTIVE_CHAT_KEY); if (!raw) return null;
    const o = JSON.parse(raw);
    return o && typeof o.id === "string" && o.id ? o : null;
  } catch (_) { return null; }
}
const emptyConsult =
  '<div class="chat-empty"><span class="emoji">✦</span>'
  + '<div class="big">Consult the Oracle</div>'
  + '<div class="small">Ask about cross-project work, the board,<br/>or have it dispatch an agent for you.</div></div>';
const emptyContinue =
  '<div class="chat-empty"><span class="emoji">↩</span>'
  + '<div class="big">Continuing this chat</div>'
  + '<div class="small">Your earlier context is kept.<br/>Send a message to pick up where you left off.</div></div>';
function showChatEmpty(){ $("#log").innerHTML = currentSessionId ? emptyContinue : emptyConsult; }
function addMsg(cls, text){
  if ($("#log .chat-empty")) $("#log").innerHTML = "";
  const d = document.createElement("div"); d.className = "msg "+cls;
  if (cls.indexOf("me") >= 0) d.textContent = text; else d.innerHTML = mdLite(text);
  $("#log").appendChild(d); $("#log").scrollTop = $("#log").scrollHeight; return d;
}
function setChatTitle(t){ currentChatTitle = (t || "").trim(); $("#c-title").textContent = t || (currentSessionId ? "Chat" : "New chat"); }
async function send(){
  const inp = $("#c-input"); const text = inp.value.trim();
  if (pendingAtts.some((a) => a.status === "uploading")) { setAStatus("Hang on — still uploading…", false); return; }
  const ready = pendingAtts.filter((a) => a.status === "done" && a.path);
  if (!text && !ready.length) return;
  const wasNew = !currentSessionId;
  // Sent to the Oracle: the question plus each saved path so \`claude -p\` can read
  // the files. Shown in the bubble: the question + file names (not long paths).
  const sendText = [text].concat(ready.map((a) => a.path)).filter(Boolean).join(" ");
  const names = ready.map((a) => a.name).join(", ");
  const shown = ready.length ? (text ? text + "\\n📎 " + names : "📎 " + names) : text;
  addMsg("me", shown); inp.value = ""; inp.style.height = ""; setAStatus(""); clearAtts();
  const titleSrc = text || names;
  if (wasNew) setChatTitle(titleSrc.length > 40 ? titleSrc.slice(0,39)+"…" : titleSrc);
  const typing = document.createElement("div"); typing.className = "typing";
  typing.innerHTML = "<i></i><i></i><i></i>";
  $("#log").appendChild(typing); $("#log").scrollTop = $("#log").scrollHeight;
  $("#c-send").disabled = true;
  try {
    await streamTurn(sendText, typing);      // live SSE — reply (incl. attachment paths) renders as it arrives
  } catch(_e){
    setConn(false);
    // Streaming was unusable before any reply text showed (old browser, or a proxy
    // that buffers SSE) — fall back to the one-shot blocking turn, reusing the bubble.
    try { await blockingTurn(sendText, typing); }
    catch(e2){ setConn(false); typing.remove(); addMsg("or err", e2.message); }
  }
  $("#c-send").disabled = false;
}
// One blocking turn against /api/chat — the fallback when SSE can't be used.
async function blockingTurn(text, typing){
  const r = await api("/api/chat", { method:"POST", body: JSON.stringify({ text, sessionId: currentSessionId }) });
  setConn(true); typing.remove();
  if (r.sessionId) { currentSessionId = r.sessionId; saveActiveChat(); } // adopt the live thread id + remember it across reloads
  addMsg(r.isError ? "or err" : "or", r.reply || "(no reply)");
}
// Parse one SSE frame ("event: <x>" + "data: <json>") and dispatch to handle(event, data).
function parseSseFrame(frame, handle){
  let event = "message", data = "";
  const lines = frame.split("\\n");
  for (let i = 0; i < lines.length; i++){
    const line = lines[i];
    if (line.indexOf("event:") === 0) event = line.slice(6).trim();
    else if (line.indexOf("data:") === 0) data += line.slice(5).trim();
  }
  if (!data) return;
  let parsed; try { parsed = JSON.parse(data); } catch(_){ return; }
  handle(event, parsed);
}
// Stream one turn over SSE (POST /api/chat/stream). Throws — so send() can fall back —
// ONLY when nothing was rendered yet; once any delta shows, later errors are annotated
// in place instead (re-running the turn would duplicate the visible reply).
async function streamTurn(text, typing){
  const res = await fetch("/api/chat/stream", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ text, sessionId: currentSessionId }),
  });
  if (!res.ok || !res.body || typeof res.body.getReader !== "function") throw new Error("stream unavailable");
  setConn(true);

  let bubble = null, raw = "", gotDelta = false, sawError = false;
  const appendDelta = (t) => {
    if (!bubble) { typing.remove(); bubble = addMsg("or", ""); }
    raw += t; bubble.innerHTML = mdLite(raw);
    $("#log").scrollTop = $("#log").scrollHeight;
  };
  const handle = (event, data) => {
    if (event === "delta" && data && typeof data.text === "string") { gotDelta = true; appendDelta(data.text); }
    else if (event === "done") {
      if (data && data.sessionId) { currentSessionId = data.sessionId; saveActiveChat(); } // adopt the live thread id + remember it across reloads
      if (!bubble) { typing.remove(); bubble = addMsg(data && data.isError ? "or err" : "or", "(no reply)"); }
      else if (data && data.isError) bubble.classList.add("err");
    } else if (event === "error") {
      sawError = true;
      if (gotDelta) addMsg("or err", (data && data.message) || "stream interrupted");
    }
  };

  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  try {
    for (;;) {
      const r = await reader.read();
      if (r.done) break;
      buf += dec.decode(r.value, { stream: true });
      let idx;
      while ((idx = buf.indexOf("\\n\\n")) >= 0) {
        const frame = buf.slice(0, idx); buf = buf.slice(idx + 2);
        parseSseFrame(frame, handle);
      }
    }
  } catch(e){
    if (!gotDelta) throw e;                 // nothing shown yet → safe to fall back
    addMsg("or err", "stream interrupted"); return;
  }
  if (buf.trim()) parseSseFrame(buf, handle); // flush any trailing frame
  // Stream closed having shown nothing usable → let send() fall back to /api/chat.
  if (!gotDelta && (sawError || !bubble)) { typing.remove(); throw new Error("empty stream"); }
}
$("#c-send").onclick = send;
$("#c-input").addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); } });
// Auto-grow the composer up to its max-height.
$("#c-input").addEventListener("input", (e) => {
  const t = e.target; t.style.height = "auto"; t.style.height = Math.min(t.scrollHeight, 130) + "px";
});

// ── Attachments (image / voice → the Oracle) ──────────────
// Phones have no drag-drop or paste, so offer explicit tap targets. Each file is
// uploaded to the sidecar (POST /api/uploads) and its saved absolute path is inlined
// into the composer; the headless \`claude -p\` Oracle reads that path like any other.
// Mirrors the apps/web AttachBar flow (50 MB client ceiling; server caps at 100 MB).
const MAX_UPLOAD = 50 * 1024 * 1024;
function fmtSize(n){ return n < 1048576 ? Math.round(n/1024)+" KB" : (n/1048576).toFixed(1)+" MB"; }
function setAStatus(msg, isErr){ const el = $("#a-status"); el.textContent = msg || ""; el.className = "a-status" + (isErr ? " err" : ""); }

// Media picked/recorded for the next message. Each file uploads to the sidecar
// right away; on send its saved path is appended to the message text so the
// headless \`claude -p\` Oracle can read the file. A preview chip per file lets
// you drop it before sending — the raw path never lands in the input box.
let pendingAtts = [];
function newAttId(){ return crypto.randomUUID ? crypto.randomUUID() : "a" + Date.now() + "-" + pendingAtts.length; }
function renderTray(){
  const tray = $("#a-tray"); tray.hidden = pendingAtts.length === 0;
  tray.innerHTML = pendingAtts.map((a) => {
    const thumb = a.isImage && a.previewUrl
      ? '<img class="thumb" src="' + a.previewUrl + '" alt="">'
      : '<span class="thumb">' + (a.isAudio ? "🎵" : "📄") + '</span>';
    const st = a.status === "uploading" ? "uploading…" : a.status === "error" ? (a.error || "failed") : fmtSize(a.size);
    return '<div class="a-chip' + (a.status === "error" ? " err" : "") + '">' + thumb
      + '<div class="info"><span class="nm">' + esc(a.name) + '</span><span class="stt">' + esc(st) + '</span></div>'
      + '<button class="rm" data-rm="' + a.id + '" aria-label="Remove">✕</button></div>';
  }).join("");
}
function removeAtt(id){
  const a = pendingAtts.find((x) => x.id === id);
  if (a && a.previewUrl) URL.revokeObjectURL(a.previewUrl);
  pendingAtts = pendingAtts.filter((x) => x.id !== id); renderTray();
}
function clearAtts(){
  for (const a of pendingAtts) if (a.previewUrl) URL.revokeObjectURL(a.previewUrl);
  pendingAtts = []; renderTray();
}
async function uploadAttachment(file){
  const isImage = (file.type || "").startsWith("image/");
  const isAudio = (file.type || "").startsWith("audio/");
  const att = {
    id: newAttId(), name: file.name || "upload", size: file.size, isImage, isAudio,
    previewUrl: isImage ? URL.createObjectURL(file) : null, status: "uploading", path: null,
  };
  pendingAtts.push(att);
  if (file.size > MAX_UPLOAD){ att.status = "error"; att.error = "too large (max " + fmtSize(MAX_UPLOAD) + ")"; renderTray(); return; }
  renderTray();
  try {
    const r = await fetch("/api/uploads?name=" + encodeURIComponent(att.name), {
      method: "POST", headers: { "content-type": file.type || "application/octet-stream" }, body: file });
    if (!r.ok) throw new Error((await r.text()) || ("HTTP " + r.status));
    const data = await r.json(); setConn(true);
    att.path = data.path; att.status = "done";
  } catch(e){ setConn(false); att.status = "error"; att.error = "upload failed"; setAStatus("Upload failed: " + e.message, true); }
  renderTray();
}
function onPick(e){ const f = e.target.files && e.target.files[0]; if (f) uploadAttachment(f); e.target.value = ""; }
$("#a-tray").addEventListener("click", (e) => {
  const rm = e.target.closest && e.target.closest("[data-rm]");
  if (rm) removeAtt(rm.dataset.rm);
});
$("#a-photo").onclick = () => $("#a-photo-input").click();
$("#a-file").onclick = () => $("#a-file-input").click();
$("#a-photo-input").addEventListener("change", onPick);
$("#a-file-input").addEventListener("change", onPick);

// Voice clip via MediaRecorder — hidden where unsupported (old iOS / insecure origin).
const canRecord = typeof window.MediaRecorder !== "undefined" && !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
if (canRecord) {
  const recBtn = $("#a-rec"); recBtn.hidden = false;
  let recorder = null, chunks = [], stream = null, recording = false;
  recBtn.onclick = async () => {
    if (recording) { if (recorder && recorder.state === "recording") recorder.stop(); return; }
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      recorder = new MediaRecorder(stream); chunks = [];
      recorder.ondataavailable = (ev) => { if (ev.data.size > 0) chunks.push(ev.data); };
      recorder.onstop = () => {
        if (stream) stream.getTracks().forEach((t) => t.stop());
        stream = null; recording = false;
        recBtn.classList.remove("rec"); recBtn.textContent = "🎤 Record";
        const type = recorder.mimeType || "audio/webm";
        const ext = (type.indexOf("mp4") >= 0 || type.indexOf("m4a") >= 0) ? "m4a" : type.indexOf("ogg") >= 0 ? "ogg" : "webm";
        const blob = new Blob(chunks, { type });
        if (blob.size > 0) uploadAttachment(new File([blob], "recording-" + Date.now() + "." + ext, { type }));
      };
      recorder.start(); recording = true;
      recBtn.classList.add("rec"); recBtn.textContent = "⏹ Stop";
    } catch(e){ setAStatus("Mic unavailable: " + e.message, true); }
  };
}

// ── Past chats ─────────────────────────────────────────────
function ago(ms){
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return Math.floor(s/60)+"m ago";
  if (s < 86400) return Math.floor(s/3600)+"h ago";
  return Math.floor(s/86400)+"d ago";
}
function startNewChat(){
  currentSessionId = null; setChatTitle("New chat"); saveActiveChat();
  $("#chat-sessions").hidden = true; clearAtts(); setAStatus(""); showChatEmpty(); $("#c-input").focus();
}
async function selectChat(id, title){
  currentSessionId = id; setChatTitle(title); saveActiveChat();
  $("#chat-sessions").hidden = true; clearAtts(); setAStatus(""); showChatEmpty(); $("#c-input").focus();
}
// Restore the chat you were in across a page reload. Validate the stored id against
// the live list so a deleted session falls back to a fresh chat; keep it on a network
// error so a transient outage doesn't wipe the active conversation.
async function restoreActiveChat(){
  const saved = readActiveChat();
  if (!saved) return;
  try {
    const list = await api("/api/chat/sessions"); setConn(true);
    const match = Array.isArray(list) ? list.find((s) => s.id === saved.id) : null;
    if (!match) { saveActiveChat(); return; } // currentSessionId still null → clears the stale entry
    currentSessionId = match.id; setChatTitle(match.title || saved.title || "Chat"); showChatEmpty();
  } catch (_) { setConn(false); /* offline — retry on next reload, keep stored id */ }
}
async function loadChatSessions(){
  const el = $("#chat-sessions");
  el.innerHTML = '<div class="chat-srow"><div class="st"><div class="ct" style="color:var(--dim)">Loading…</div></div></div>';
  try {
    const list = await api("/api/chat/sessions"); setConn(true);
    if (!Array.isArray(list) || !list.length) {
      el.innerHTML = '<div class="chat-srow"><div class="st"><div class="ct" style="color:var(--dim)">No past chats yet</div></div></div>';
      return;
    }
    el.innerHTML = list.map((s) =>
      '<div class="chat-srow'+(s.id===currentSessionId?" active":"")+'" data-id="'+esc(s.id)+'" data-title="'+esc(s.title||"Chat")+'">'
      + '<div class="st"><div class="ct">'+esc(s.title||"Chat")+'</div>'
      + '<div class="ca">'+ago(s.updatedAt)+'</div></div>'
      + '<button class="cx" data-del="'+esc(s.id)+'" aria-label="Delete">✕</button></div>'
    ).join("");
  } catch(e){ setConn(false); el.innerHTML = '<div class="chat-srow"><div class="st"><div class="ct" style="color:var(--bad)">'+esc(e.message)+'</div></div></div>'; }
}
$("#c-new").onclick = startNewChat;
$("#c-history").onclick = () => {
  const el = $("#chat-sessions");
  if (el.hidden) { el.hidden = false; loadChatSessions(); } else { el.hidden = true; }
};
$("#chat-sessions").addEventListener("click", (e) => {
  const del = e.target.closest && e.target.closest("[data-del]");
  if (del) {
    e.stopPropagation();
    const id = del.dataset.del;
    api("/api/chat/sessions/delete", { method:"POST", body: JSON.stringify({ id }) })
      .then(() => { if (id === currentSessionId) startNewChat(); loadChatSessions(); })
      .catch((err) => setConn(false) || alert("Couldn't delete: "+err.message));
    return;
  }
  const row = e.target.closest && e.target.closest(".chat-srow[data-id]");
  if (row) selectChat(row.dataset.id, row.dataset.title);
});
setChatTitle("New chat");
showChatEmpty();

// ── PWA install hint (iOS Add to Home Screen) ─────────────
// Web Push on iOS only works once the app is installed to the home screen, so
// nudge Safari users to do that — but only when not already standalone and not
// dismissed before. Android/desktop get the platform prompt elsewhere, so we
// keep the hint iOS-focused.
const isStandalone = window.matchMedia("(display-mode: standalone)").matches
  || navigator.standalone === true;
function renderInstallHint(){
  const host = $("#install-hint"); if (!host) return;
  const ua = navigator.userAgent;
  const isIOS = /iphone|ipad|ipod/i.test(ua) && !window.MSStream;
  if (isStandalone || !isIOS || localStorage.getItem("oracle-install-dismissed")) { host.innerHTML = ""; return; }
  host.innerHTML =
    '<div class="install"><span class="ic">📲</span>'
    + '<div class="tx">Add Oracle to your Home Screen'
    + '<div class="small">Tap '
    + '<svg class="share" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 16V4M8 8l4-4 4 4"/><path d="M5 12v7a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-7"/></svg>'
    + ' then <b>Add to Home Screen</b> for quick access.</div></div>'
    + '<button class="x" id="install-x" aria-label="Dismiss">✕</button></div>';
  $("#install-x").onclick = () => { localStorage.setItem("oracle-install-dismissed", "1"); host.innerHTML = ""; };
}
renderInstallHint();

// ── Resume / reconnect ────────────────────────────────────
// Mobile Safari/Chrome suspend the page and drop in-flight requests while the phone is
// locked or the tab is backgrounded. On resume the visible list is stale and the
// connection pill can be stuck on "offline". Re-fetch the active tab so it recovers
// silently instead of stranding a "Failed to fetch" error. The retry-aware api() above
// absorbs the first network blip during the handover.
function reloadActiveTab(){
  const active = document.querySelector("nav button.active");
  const tab = active && active.dataset.tab;
  if (tab === "issues") loadIssues();
  else if (tab === "sessions") loadSessions();
  // Chat has no list to refresh; its SSE turn is one-shot per send.
}
const onResume = () => {
  if (document.visibilityState === "hidden") return;
  if (!navigator.onLine) return;
  reloadActiveTab();
};
document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") onResume(); });
window.addEventListener("online", onResume);
window.addEventListener("pageshow", onResume); // bfcache restore
window.addEventListener("offline", () => setConn(false));

// ── Boot ──────────────────────────────────────────────────
// Deep-link: /?session=<id> jumps to the Sessions tab and
// opens that session's reply box once the list renders (pendingReplyId is consumed
// by loadSessions). Otherwise land on Issues as usual.
(function () {
  let sid = null;
  try { sid = new URLSearchParams(location.search).get("session"); } catch (_) { sid = null; }
  restoreActiveChat(); // re-open the chat you were in (no-op if none); independent of the landing tab
  if (sid) {
    pendingReplyId = sid;
    const tabBtn = document.querySelector('nav button[data-tab="sessions"]');
    if (tabBtn) { tabBtn.click(); return; } // click() loads the session list
  }
  loadIssues();
})();
</script>
</body>
</html>`;

// ── PWA install assets ───────────────────────────────────────────────────────
// Served so the phone console can be added to the home screen and launch
// standalone. Notifications are handled over Telegram, so there is no service
// worker or Web Push here.

export const webManifest = {
  name: "Oracle",
  short_name: "Oracle",
  start_url: "/",
  display: "standalone",
  theme_color: "#0b0d12",
  background_color: "#0b0d12",
  icons: [
    { src: "/icon-192.png", sizes: "192x192", type: "image/png", purpose: "any maskable" },
    { src: "/icon-512.png", sizes: "512x512", type: "image/png", purpose: "any maskable" },
  ],
};

/** A tiny solid-color PNG (the app's --bg navy), generated in-code so we don't
 *  ship a binary asset. Same single pixel for both /icon-192 and /icon-512 — the
 *  browser scales it. */
export function iconPng(): Buffer {
  return buildSolidPng(0x0b, 0x0d, 0x12);
}

function buildSolidPng(r: number, g: number, b: number): Buffer {
  // Minimal 1x1 8-bit RGB PNG.
  const crcTable = (() => {
    const t: number[] = [];
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      t[n] = c >>> 0;
    }
    return t;
  })();
  const crc32 = (buf: Buffer): number => {
    let c = 0xffffffff;
    for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]!)! & 0xff]! ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type: string, data: Buffer): Buffer => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length, 0);
    const typeBuf = Buffer.from(type, "ascii");
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
    return Buffer.concat([len, typeBuf, data, crc]);
  };

  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(1, 0); // width
  ihdr.writeUInt32BE(1, 4); // height
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // color type: truecolor RGB
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  // raw scanline: filter byte 0 + RGB
  const raw = Buffer.from([0, r, g, b]);
  // zlib stored block (no compression): 0x78 0x01 header, then deflate stored.
  const zlibHeader = Buffer.from([0x78, 0x01]);
  const blockHeader = Buffer.from([0x01]); // final stored block
  const lenLE = Buffer.alloc(4);
  lenLE.writeUInt16LE(raw.length, 0);
  lenLE.writeUInt16LE(~raw.length & 0xffff, 2);
  const adler = (() => {
    let a = 1;
    let bb = 0;
    for (let i = 0; i < raw.length; i++) {
      a = (a + raw[i]!) % 65521;
      bb = (bb + a) % 65521;
    }
    const out = Buffer.alloc(4);
    out.writeUInt32BE((bb << 16) | a, 0);
    return out;
  })();
  const idatData = Buffer.concat([zlibHeader, blockHeader, lenLE, raw, adler]);

  return Buffer.concat([
    sig,
    chunk("IHDR", ihdr),
    chunk("IDAT", idatData),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}
