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
<!-- PWA install + web-push (juancode-6f0) -->
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

  /* ── Notifications opt-in ─────────────────────────────── */
  .push {
    display: flex; align-items: center; gap: 12px; padding: 14px;
  }
  .push .ic {
    width: 38px; height: 38px; flex: none; border-radius: 11px; display: grid; place-items: center;
    font-size: 18px; background: var(--panel-2); box-shadow: inset 0 0 0 1px var(--line);
  }
  .push.on .ic { background: rgba(88,224,140,.14); box-shadow: inset 0 0 0 1px rgba(88,224,140,.3); }
  .push .tx { flex: 1; min-width: 0; }
  .push .tx .h { font-size: 14.5px; font-weight: 640; }
  .push .tx .d { font-size: 12.5px; color: var(--dim); margin-top: 2px; }
  .push .act {
    flex: none; min-height: 38px; padding: 0 15px; border: 0; border-radius: 10px;
    background: linear-gradient(180deg, var(--tint), var(--tint-strong)); color: var(--tint-ink);
    font-size: 13.5px; font-weight: 700; box-shadow: 0 2px 10px rgba(60,110,230,.25);
  }
  .push .act.off { background: var(--panel-2); color: var(--txt); box-shadow: inset 0 0 0 1px var(--line); }
  .push .act.muted { background: var(--panel-2); color: var(--faint); box-shadow: inset 0 0 0 1px var(--line-soft); }
  .push .act:disabled { opacity: .6; }

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
  .composer {
    display: flex; gap: 9px; align-items: flex-end; padding: 10px 0 calc(var(--sab) + 6px);
    position: sticky; bottom: 0;
    background: linear-gradient(transparent, var(--bg) 28%);
  }
  .composer textarea {
    flex: 1; min-height: var(--tap); max-height: 130px; height: var(--tap);
    border-radius: 22px; padding: 12px 16px; background: var(--panel);
  }
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
  /* Chat session bar + past-chats list */
  #chat-bar { display: flex; align-items: center; gap: 8px; padding: 4px 0 6px; }
  #c-title { flex: 1; min-width: 0; font-size: 13px; font-weight: 600; color: var(--faint);
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .chat-pill {
    flex: none; padding: 5px 11px; min-height: 32px;
    border: 0; border-radius: 999px; background: var(--panel); color: var(--faint);
    box-shadow: inset 0 0 0 1px var(--line-soft); font-size: 12px; font-weight: 600;
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
      <div id="push-panel"></div>

      <details>
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
      <details>
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
        <div id="chat-bar">
          <button id="c-history" class="chat-pill" aria-label="Past chats">☰ Chats</button>
          <span id="c-title">New chat</span>
          <button id="c-new" class="chat-pill">＋ New</button>
        </div>
        <div id="chat-sessions" hidden></div>
        <div id="log"></div>
        <div class="composer">
          <textarea id="c-input" placeholder="Ask the Oracle…" rows="1"></textarea>
          <button id="c-send" class="send" aria-label="Send">➤</button>
        </div>
      </div>
    </section>
  </main>

<script>
const $ = (s) => document.querySelector(s);
const api = async (path, opts) => {
  const r = await fetch(path, { headers: { "content-type": "application/json" }, ...opts });
  if (!r.ok) throw new Error((await r.text()) || ("HTTP " + r.status));
  return r.json();
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
      return '<div class="card item"><div class="row"><span class="title">'+esc(s.title||"untitled")+'</span>'
      + '<span class="badge b-open spacer">'+esc(s.provider||"agent")+'</span></div>'
      + '<div class="meta"><span class="mono">'+esc(s.cwd||"")+'</span>'
      + (s.status?'<span class="badge '+(live?"b-ready":"b-closed")+'">'+esc(s.status)+'</span>':'')
      + '</div></div>';
    }).join("");
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
function setChatTitle(t){ $("#c-title").textContent = t || (currentSessionId ? "Chat" : "New chat"); }
async function send(){
  const inp = $("#c-input"); const text = inp.value.trim(); if (!text) return;
  const wasNew = !currentSessionId;
  addMsg("me", text); inp.value = ""; inp.style.height = "";
  if (wasNew) setChatTitle(text.length > 40 ? text.slice(0,39)+"…" : text);
  const typing = document.createElement("div"); typing.className = "typing";
  typing.innerHTML = "<i></i><i></i><i></i>";
  $("#log").appendChild(typing); $("#log").scrollTop = $("#log").scrollHeight;
  $("#c-send").disabled = true;
  try {
    const r = await api("/api/chat", { method:"POST", body: JSON.stringify({ text, sessionId: currentSessionId }) }); setConn(true);
    typing.remove();
    if (r.sessionId) currentSessionId = r.sessionId; // adopt the live thread id
    addMsg(r.isError ? "or err" : "or", r.reply || "(no reply)");
  } catch(e){ setConn(false); typing.remove(); addMsg("or err", e.message); }
  $("#c-send").disabled = false;
}
$("#c-send").onclick = send;
$("#c-input").addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); } });
// Auto-grow the composer up to its max-height.
$("#c-input").addEventListener("input", (e) => {
  const t = e.target; t.style.height = "auto"; t.style.height = Math.min(t.scrollHeight, 130) + "px";
});

// ── Past chats ─────────────────────────────────────────────
function ago(ms){
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return Math.floor(s/60)+"m ago";
  if (s < 86400) return Math.floor(s/3600)+"h ago";
  return Math.floor(s/86400)+"d ago";
}
function startNewChat(){
  currentSessionId = null; setChatTitle("New chat");
  $("#chat-sessions").hidden = true; showChatEmpty(); $("#c-input").focus();
}
async function selectChat(id, title){
  currentSessionId = id; setChatTitle(title);
  $("#chat-sessions").hidden = true; showChatEmpty(); $("#c-input").focus();
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
    + ' then <b>Add to Home Screen</b>. Needed for push alerts on iPhone.</div></div>'
    + '<button class="x" id="install-x" aria-label="Dismiss">✕</button></div>';
  $("#install-x").onclick = () => { localStorage.setItem("oracle-install-dismissed", "1"); host.innerHTML = ""; };
}
renderInstallHint();

// ── Notifications opt-in ──────────────────────────────────
// Registers /sw.js, requests permission, subscribes with the VAPID key from
// /api/push/vapid, and POSTs the subscription to /api/push/subscribe. Off-path
// hits /api/push/unsubscribe. Renders a stateful card with clear copy.
function urlBase64ToUint8Array(base64String){
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
  const rawData = atob(base64);
  const out = new Uint8Array(rawData.length);
  for (let i = 0; i < rawData.length; i++) out[i] = rawData.charCodeAt(i);
  return out;
}
const pushSupported = ("serviceWorker" in navigator) && ("PushManager" in window) && ("Notification" in window);

// Render the opt-in card for a given state: on | default | denied | unsupported | working
function renderPush(state){
  const host = $("#push-panel"); if (!host) return;
  // iOS requires the PWA be installed before push is available at all.
  if (pushSupported && !isStandalone && /iphone|ipad|ipod/i.test(navigator.userAgent)) { host.innerHTML = ""; return; }
  if (!pushSupported) {
    host.innerHTML = '<div class="card push"><span class="ic">🔕</span>'
      + '<div class="tx"><div class="h">Alerts unavailable</div>'
      + '<div class="d">This browser can\\'t do push notifications.</div></div></div>';
    return;
  }
  let ic = "🔔", h = "Get alerts on this phone", d = "Push when a session needs you or finishes.";
  let act = '<button class="act" id="push-act">Turn on</button>', cls = "";
  if (state === "working") { act = '<button class="act" id="push-act" disabled>…</button>'; }
  else if (state === "on") { cls = "on"; h = "Alerts are on"; d = "You'll be pinged for sessions & tracked PRs.";
    act = '<button class="act off" id="push-act">Turn off</button>'; }
  else if (state === "denied") { ic = "🔕"; h = "Alerts are blocked";
    d = "Enable notifications for this site in your browser settings.";
    act = '<button class="act muted" id="push-act" disabled>Blocked</button>'; }
  host.innerHTML = '<div class="card push '+cls+'"><span class="ic">'+ic+'</span>'
    + '<div class="tx"><div class="h">'+h+'</div><div class="d">'+d+'</div></div>'+act+'</div>';
  const a = $("#push-act");
  if (a && !a.disabled) a.onclick = state === "on" ? disablePush : enablePush;
}
async function refreshPushState(){
  if (!pushSupported) { renderPush("unsupported"); return; }
  if (Notification.permission === "denied") { renderPush("denied"); return; }
  if (Notification.permission === "granted") {
    try {
      const reg = await navigator.serviceWorker.getRegistration();
      const sub = reg && await reg.pushManager.getSubscription();
      renderPush(sub ? "on" : "default");
    } catch(_) { renderPush("default"); }
    return;
  }
  renderPush("default");
}
async function enablePush(){
  renderPush("working");
  try {
    const reg = await navigator.serviceWorker.register("/sw.js");
    const perm = await Notification.requestPermission();
    if (perm !== "granted") { refreshPushState(); return; }
    const { publicKey } = await api("/api/push/vapid");
    if (!publicKey) throw new Error("the server has no VAPID key");
    let sub = await reg.pushManager.getSubscription();
    if (!sub) {
      sub = await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(publicKey),
      });
    }
    await api("/api/push/subscribe", { method:"POST", body: JSON.stringify(sub) });
    renderPush("on");
  } catch(e){ alert("Couldn't turn on alerts: " + e.message); refreshPushState(); }
}
async function disablePush(){
  renderPush("working");
  try {
    const reg = await navigator.serviceWorker.getRegistration();
    const sub = reg && await reg.pushManager.getSubscription();
    if (sub) {
      await api("/api/push/unsubscribe", { method:"POST", body: JSON.stringify({ endpoint: sub.endpoint }) }).catch(()=>{});
      await sub.unsubscribe().catch(()=>{});
    }
  } catch(_){}
  renderPush("default");
}
refreshPushState();

// ── Boot ──────────────────────────────────────────────────
loadIssues();
</script>
</body>
</html>`;
