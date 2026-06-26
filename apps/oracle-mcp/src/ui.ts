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
<title>Oracle</title>
<style>
  :root {
    --bg: #0b0d12; --panel: #151922; --panel-2: #1c2230; --line: #262d3b;
    --txt: #e7ebf2; --dim: #8a93a6; --tint: #7aa2ff; --good: #4ade80;
    --warn: #fbbf24; --bad: #f87171; --radius: 12px;
  }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  html, body { margin: 0; height: 100%; background: var(--bg); color: var(--txt);
    font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
  body { display: flex; flex-direction: column;
    padding: env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left); }
  header { display: flex; align-items: center; gap: 9px; padding: 14px 16px 10px;
    position: sticky; top: 0; background: linear-gradient(var(--bg), var(--bg) 70%, transparent); z-index: 5; }
  header .spark { font-size: 18px; }
  header h1 { font-size: 17px; font-weight: 650; margin: 0; letter-spacing: .2px; }
  header .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--dim); margin-left: auto; }
  header .dot.ok { background: var(--good); } header .dot.bad { background: var(--bad); }
  nav { display: flex; gap: 6px; padding: 0 12px 10px; }
  nav button { flex: 1; padding: 9px; border: 0; border-radius: 10px; background: var(--panel);
    color: var(--dim); font-size: 14px; font-weight: 600; }
  nav button.active { background: var(--panel-2); color: var(--txt); box-shadow: inset 0 0 0 1px var(--line); }
  main { flex: 1; overflow-y: auto; padding: 4px 12px 24px; }
  .tab { display: none; } .tab.active { display: block; }
  .card { background: var(--panel); border: 1px solid var(--line); border-radius: var(--radius);
    padding: 12px 13px; margin-bottom: 9px; }
  .row { display: flex; align-items: baseline; gap: 8px; }
  .id { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--tint); }
  .title { font-weight: 550; }
  .meta { color: var(--dim); font-size: 12px; margin-top: 3px; display: flex; gap: 8px; flex-wrap: wrap; }
  .badge { font-size: 11px; font-weight: 700; padding: 1px 7px; border-radius: 999px; }
  .b-ready { background: rgba(74,222,128,.16); color: var(--good); }
  .b-open { background: rgba(122,162,255,.16); color: var(--tint); }
  .b-closed { background: rgba(138,147,166,.16); color: var(--dim); }
  .b-p0,.b-p1 { background: rgba(248,113,113,.16); color: var(--bad); }
  .b-p2 { background: rgba(251,191,36,.16); color: var(--warn); }
  label { display: block; font-size: 12px; color: var(--dim); margin: 8px 0 4px; }
  input, textarea, select { width: 100%; background: var(--panel-2); color: var(--txt);
    border: 1px solid var(--line); border-radius: 9px; padding: 10px; font-size: 15px; }
  textarea { resize: vertical; min-height: 44px; }
  .btn { width: 100%; padding: 12px; border: 0; border-radius: 10px; background: var(--tint);
    color: #08122e; font-size: 15px; font-weight: 700; margin-top: 12px; }
  .btn.ghost { background: var(--panel-2); color: var(--txt); box-shadow: inset 0 0 0 1px var(--line); }
  .btn:disabled { opacity: .5; }
  details > summary { cursor: pointer; color: var(--tint); font-weight: 600; font-size: 14px;
    list-style: none; padding: 4px 0; }
  details > summary::-webkit-details-marker { display: none; }
  .hint { color: var(--dim); font-size: 12px; text-align: center; padding: 24px 0; }
  /* chat */
  #chat { display: flex; flex-direction: column; height: 100%; }
  #log { flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: 8px; padding-bottom: 8px; }
  .msg { max-width: 86%; padding: 9px 12px; border-radius: 14px; white-space: pre-wrap; word-break: break-word; }
  .msg.me { align-self: flex-end; background: var(--tint); color: #08122e; border-bottom-right-radius: 4px; }
  .msg.or { align-self: flex-start; background: var(--panel-2); border: 1px solid var(--line); border-bottom-left-radius: 4px; }
  .msg.err { border-color: var(--bad); color: var(--bad); }
  .composer { display: flex; gap: 8px; padding-top: 8px; position: sticky; bottom: 0; background: var(--bg); }
  .composer textarea { flex: 1; min-height: 0; height: 44px; }
  .composer button { width: 56px; border: 0; border-radius: 10px; background: var(--tint); color: #08122e; font-size: 20px; font-weight: 800; }
  .typing { color: var(--dim); font-size: 13px; align-self: flex-start; padding: 4px 6px; }
</style>
</head>
<body>
  <header>
    <span class="spark">✦</span><h1>Oracle</h1><span id="status" class="dot"></span>
  </header>
  <nav>
    <button data-tab="issues" class="active">Issues</button>
    <button data-tab="sessions">Sessions</button>
    <button data-tab="chat">Chat</button>
  </nav>
  <main>
    <section id="issues" class="tab active">
      <details><summary>＋ New global issue</summary>
        <div class="card">
          <label>Title</label><input id="i-title" placeholder="Short title" />
          <label>Description</label><textarea id="i-desc" placeholder="Context (optional)"></textarea>
          <div class="row" style="gap:10px">
            <div style="flex:1"><label>Type</label>
              <select id="i-type"><option>task</option><option>feature</option><option>bug</option><option>chore</option><option>epic</option></select></div>
            <div style="flex:1"><label>Priority</label>
              <select id="i-prio"><option value="0">0</option><option value="1">1</option><option value="2" selected>2</option><option value="3">3</option><option value="4">4</option></select></div>
          </div>
          <button class="btn" id="i-create">Create</button>
        </div>
      </details>
      <div id="issues-list"><div class="hint">Loading…</div></div>
    </section>

    <section id="sessions" class="tab">
      <details><summary>➤ Dispatch an agent</summary>
        <div class="card">
          <label>Project path (absolute)</label><input id="d-project" placeholder="/Users/you/repo" />
          <label>Prompt</label><textarea id="d-prompt" placeholder="What should the agent do?"></textarea>
          <div class="row" style="gap:10px">
            <div style="flex:1"><label>Provider</label>
              <select id="d-prov"><option>claude</option><option>codex</option></select></div>
            <div style="flex:1"><label>Worktree</label>
              <select id="d-wt"><option value="false">no</option><option value="true">yes</option></select></div>
          </div>
          <button class="btn" id="d-go">Dispatch</button>
        </div>
      </details>
      <div id="sessions-list"><div class="hint">Loading…</div></div>
    </section>

    <section id="chat" class="tab">
      <div id="chat">
        <div id="log"><div class="hint">Ask the Oracle about cross-project work, the board, or to dispatch agents.</div></div>
        <div class="composer">
          <textarea id="c-input" placeholder="Ask the Oracle…" rows="1"></textarea>
          <button id="c-send">➤</button>
        </div>
      </div>
    </section>
  </main>

<script>
const $ = (s) => document.querySelector(s);
const api = async (path, opts) => {
  const r = await fetch(path, { headers: { "content-type": "application/json" }, ...opts });
  if (!r.ok) throw new Error((await r.text()) || r.status);
  return r.json();
};
const setStatus = (ok) => { $("#status").className = "dot " + (ok ? "ok" : "bad"); };

// tabs
document.querySelectorAll("nav button").forEach((b) => b.onclick = () => {
  document.querySelectorAll("nav button").forEach((x) => x.classList.toggle("active", x === b));
  document.querySelectorAll(".tab").forEach((t) => t.classList.toggle("active", t.id === b.dataset.tab));
  if (b.dataset.tab === "issues") loadIssues();
  if (b.dataset.tab === "sessions") loadSessions();
});

// issues
function prioBadge(p){ return '<span class="badge b-p'+p+'">P'+p+'</span>'; }
function statusBadge(s){ const c = s==="closed"?"b-closed":"b-open"; return '<span class="badge '+c+'">'+s+'</span>'; }
async function loadIssues(){
  const el = $("#issues-list");
  try {
    const items = await api("/api/issues"); setStatus(true);
    if (!items.length) { el.innerHTML = '<div class="hint">No global issues yet.</div>'; return; }
    el.innerHTML = items.map((i) => '<div class="card"><div class="row"><span class="id">'+i.id+'</span>'
      + prioBadge(i.priority) + statusBadge(i.status) + (i.ready?'<span class="badge b-ready">ready</span>':'')
      + '</div><div class="title">'+esc(i.title)+'</div>'
      + '<div class="meta"><span>'+i.issueType+'</span>'+(i.parent?'<span>↑ '+i.parent+'</span>':'')+'</div></div>').join("");
  } catch(e){ setStatus(false); el.innerHTML = '<div class="hint">'+esc(e.message)+'</div>'; }
}
$("#i-create").onclick = async () => {
  const btn = $("#i-create"); btn.disabled = true; btn.textContent = "Creating…";
  try {
    await api("/api/issues", { method:"POST", body: JSON.stringify({
      title: $("#i-title").value.trim(), description: $("#i-desc").value.trim() || undefined,
      type: $("#i-type").value, priority: Number($("#i-prio").value) }) });
    $("#i-title").value = $("#i-desc").value = "";
    await loadIssues();
  } catch(e){ alert("Create failed: "+e.message); }
  btn.disabled = false; btn.textContent = "Create";
};

// sessions
async function loadSessions(){
  const el = $("#sessions-list");
  try {
    const data = await api("/api/sessions"); setStatus(true);
    const list = Array.isArray(data) ? data : (data.sessions || []);
    if (!list.length) { el.innerHTML = '<div class="hint">No sessions running.</div>'; return; }
    el.innerHTML = list.map((s) => '<div class="card"><div class="row"><span class="title">'+esc(s.title||"untitled")+'</span>'
      + '<span class="badge b-open" style="margin-left:auto">'+(s.provider||"")+'</span></div>'
      + '<div class="meta"><span>'+esc(s.cwd||"")+'</span><span>'+(s.status||"")+'</span></div></div>').join("");
  } catch(e){ setStatus(false); el.innerHTML = '<div class="hint">'+esc(e.message)+'</div>'; }
}
$("#d-go").onclick = async () => {
  const btn = $("#d-go"); btn.disabled = true; btn.textContent = "Dispatching…";
  try {
    await api("/api/dispatch", { method:"POST", body: JSON.stringify({
      project: $("#d-project").value.trim(), prompt: $("#d-prompt").value.trim(),
      provider: $("#d-prov").value, worktree: $("#d-wt").value === "true" }) });
    $("#d-prompt").value = "";
    alert("Dispatched. It'll appear in the session list on the Mac.");
    await loadSessions();
  } catch(e){ alert("Dispatch failed: "+e.message); }
  btn.disabled = false; btn.textContent = "Dispatch";
};

// chat
// Minimal, XSS-safe markdown: escape first, then **bold**, \`code\`, and bullets.
function mdLite(s){ return esc(s)
  .replace(/\\*\\*([^*]+)\\*\\*/g, "<b>$1</b>")
  .replace(/\`([^\`]+)\`/g, '<code style="background:rgba(255,255,255,.08);padding:1px 4px;border-radius:4px">$1</code>')
  .replace(/^[-*] /gm, "• "); }
function addMsg(cls, text){ const d = document.createElement("div"); d.className = "msg "+cls;
  if (cls.indexOf("me") >= 0) d.textContent = text; else d.innerHTML = mdLite(text);
  $("#log").appendChild(d); $("#log").scrollTop = $("#log").scrollHeight; return d; }
async function send(){
  const inp = $("#c-input"); const text = inp.value.trim(); if (!text) return;
  if ($("#log .hint")) $("#log").innerHTML = "";
  addMsg("me", text); inp.value = "";
  const typing = document.createElement("div"); typing.className = "typing"; typing.textContent = "Oracle is thinking…";
  $("#log").appendChild(typing); $("#log").scrollTop = $("#log").scrollHeight;
  $("#c-send").disabled = true;
  try {
    const r = await api("/api/chat", { method:"POST", body: JSON.stringify({ text }) }); setStatus(true);
    typing.remove();
    addMsg(r.isError ? "or err" : "or", r.reply || "(no reply)");
  } catch(e){ setStatus(false); typing.remove(); addMsg("or err", e.message); }
  $("#c-send").disabled = false;
}
$("#c-send").onclick = send;
$("#c-input").addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); } });

function esc(s){ return String(s).replace(/[&<>"]/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])); }
loadIssues();
</script>
</body>
</html>`;
