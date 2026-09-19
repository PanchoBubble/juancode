#!/bin/bash
#
# The honest test for juancode-hz7n.2: a live session survives a daemon re-exec onto
# a different binary.
#
# A unit test of the handoff map proves nothing that matters here. What matters is a
# real child on a real pty living through a real `execv`, so this boots a daemon of its
# own — its own port, its own socket, its own data directory, never the user's — runs a
# fake CLI in it, swaps the daemon's code underneath, and then asks the four questions
# the ticket asks:
#
#   1. same daemon pid, different binary behind it
#   2. same child pid, still a child of that daemon
#   3. the session still reads `running`, and typing into it still reaches the CLI
#   4. the scrollback spans the swap with no gap: what was said before the exec, what
#      the CLI said while it happened, and what it said after, all in one history
#
# Usage: apps/juancoded/scripts/reexec-live-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
TMP=$(mktemp -d "${TMPDIR:-/tmp}/juancoded-reexec.XXXXXX")
# Resolved, because `lsof` reports the real path and the comparison below is exact.
TMP=$(cd "$TMP" && pwd -P)
PORT=${REEXEC_TEST_PORT:-14829}
DAEMON_PID=""
CHILD_PID=""

# Fires on every exit path, not just the happy one. Nothing this script starts may
# outlive it: a stranded daemon holds a pty and a fake CLI forever.
cleanup() {
  local status=$?
  set +e
  if [ -n "$CHILD_PID" ]; then kill -9 "$CHILD_PID" 2>/dev/null; fi
  if [ -n "$DAEMON_PID" ]; then
    kill -TERM "$DAEMON_PID" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$DAEMON_PID" 2>/dev/null || break
      sleep 0.3
    done
    kill -9 "$DAEMON_PID" 2>/dev/null
  fi
  pkill -9 -f "$TMP/fake-claude" 2>/dev/null
  if [ "$status" -ne 0 ] && [ -s "$TMP/daemon.log" ]; then
    # Kept, not printed and lost: a failure here is usually something the daemon said
    # on its way through the swap, and the temp tree is about to go.
    cp "$TMP/daemon.log" "${TMPDIR:-/tmp}/juancoded-reexec-failure.log"
    echo "--- daemon log (kept at ${TMPDIR:-/tmp}/juancoded-reexec-failure.log) ---"
    tail -40 "$TMP/daemon.log"
  fi
  rm -rf "$TMP"
  exit "$status"
}
trap cleanup EXIT INT TERM

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# A fake CLI has to ECHO or nothing about delivery is measurable, and it has to look
# busy ("esc to interrupt") or the activity classifier never fires. `read` blocks, so
# this is a bounded workload and never a spin loop.
# `stream:N` is how it stands in for a CLI mid-response: N numbered lines, paced, so
# the swap can be triggered while it is still talking. The loop is counted and ends by
# itself — never a spin loop, and nothing it starts outlives it.
cat > "$TMP/fake-claude" <<'CLI'
#!/bin/sh
printf 'FAKE-CLI-READY\r\n'
printf 'esc to interrupt\r\n'
while IFS= read -r line; do
  case "$line" in
    stream:*)
      n=${line#stream:}
      i=1
      while [ "$i" -le "$n" ]; do
        printf 'line-%s\r\n' "$i"
        if [ $((i % 20)) -eq 0 ]; then printf 'esc to interrupt\r\n'; fi
        i=$((i + 1))
        sleep 0.05
      done
      printf 'stream-done\r\n'
      ;;
    *)
      printf 'echo:%s\r\n' "$line"
      ;;
  esac
  printf 'esc to interrupt\r\n'
done
CLI
chmod +x "$TMP/fake-claude"

say "building the daemon"
cargo build -p juancoded >/dev/null
# Two paths, one build: `ps -o comm=` names the image a pid is running, so a copy under
# a second name is how "the same process is running different code" becomes observable
# rather than asserted.
cp target/debug/juancoded "$TMP/juancoded-v1"
cp target/debug/juancoded "$TMP/juancoded-v2"

say "booting a daemon on :$PORT (not the user's)"
env JUANCODED_PORT="$PORT" \
    JUANCODED_SOCKET="$TMP/daemon.sock" \
    JUANCODED_DATA_DIR="$TMP/data" \
    JUANCODE_CLAUDE_BIN="$TMP/fake-claude" \
    JUANCODED_REEXEC=1 \
    JUANCODED_LOG=info \
    "$TMP/juancoded-v1" >"$TMP/daemon.log" 2>&1 &
DAEMON_PID=$!

for _ in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break
  kill -0 "$DAEMON_PID" 2>/dev/null || fail "the daemon exited while starting"
  sleep 0.25
done
curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null || fail "the daemon never answered"
echo "daemon pid $DAEMON_PID"

cat > "$TMP/ws.mjs" <<'NODE'
// A minimal client over Node 22's global WebSocket. Two modes: `create` opens a
// session and types into it, `attach` re-attaches to one that already exists.
const [, , mode, port, arg, text] = process.argv;
const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`);
let seen = '';
let sessionId = arg;
let meta = null;
let identity = null;
const die = (why) => { console.error(why); process.exit(1); };
const timer = setTimeout(() => die(`timed out in ${mode}; saw ${JSON.stringify(seen.slice(-400))}`), 30000);

const want = (marker) => new Promise((resolve) => {
  const check = () => { if (seen.includes(marker)) { resolve(); return true; } return false; };
  if (check()) return;
  waiters.push({ check, resolve });
});
const waiters = [];

ws.onmessage = async (ev) => {
  const m = JSON.parse(ev.data);
  if (m.type === 'serverInfo') { identity = m.identity; return; }
  if (m.type === 'created') { meta = m.session; sessionId = m.session.id; return; }
  if (m.type === 'attached') { meta = m.session; seen += m.scrollback; }
  if (m.type === 'output') seen += m.data;
  for (let i = waiters.length - 1; i >= 0; i--) if (waiters[i].check()) waiters.splice(i, 1);
};
ws.onerror = (e) => die(`socket error: ${e.message ?? e}`);

ws.onopen = async () => {
  if (mode === 'create') {
    ws.send(JSON.stringify({ type: 'create', provider: 'claude', cwd: arg, cols: 100, rows: 30 }));
    while (!sessionId) await new Promise((r) => setTimeout(r, 25));
    await want('FAKE-CLI-READY');
  } else {
    ws.send(JSON.stringify({ type: 'attach', sessionId, cols: 100, rows: 30 }));
    while (!meta) await new Promise((r) => setTimeout(r, 25));
  }
  if (text) {
    ws.send(JSON.stringify({ type: 'input', sessionId, data: `${text}\r` }));
    await want(`echo:${text}`);
  }
  clearTimeout(timer);
  console.log(JSON.stringify({
    sessionId,
    status: meta?.status,
    buildStampMs: identity?.buildStampMs,
    seen,
  }));
  ws.close();
  process.exit(0);
};
NODE

say "creating a session and typing into it"
BEFORE=$(node "$TMP/ws.mjs" create "$PORT" "$TMP" before-swap) || fail "could not create a session"
SESSION=$(echo "$BEFORE" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).sessionId))')
STAMP_BEFORE=$(echo "$BEFORE" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).buildStampMs))')
echo "session $SESSION"
echo "$BEFORE" | grep -q 'echo:before-swap' || fail "the CLI never echoed before the swap"

CHILD_PID=$(ps -Ao pid,ppid,command | awk -v p="$DAEMON_PID" '$2==p {print $1; exit}')
[ -n "$CHILD_PID" ] || fail "the daemon has no child to carry"
echo "CLI pid $CHILD_PID"

say "re-execing onto $TMP/juancoded-v2"
# The daemon execs out from under the request, so curl never sees a response on the
# happy path. A refusal, though, is an answer — and it is the one worth printing.
REPLY=$(curl -sS -m 20 -X POST "http://127.0.0.1:$PORT/api/reexec" \
  -H 'content-type: application/json' \
  -d "{\"binary\":\"$TMP/juancoded-v2\"}" 2>&1 || true)
if [ -n "$REPLY" ]; then echo "the daemon answered rather than exec'ing: $REPLY"; fi

for _ in $(seq 1 80); do
  curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break
  sleep 0.25
done
curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null || fail "the daemon never came back after the exec"

say "the four questions"
kill -0 "$DAEMON_PID" 2>/dev/null || fail "the daemon pid changed; that was a restart, not an exec"
# NOT `ps -o comm=`: an exec that keeps argv — which is the point — keeps argv[0] too,
# so `ps` still names the binary this process started life as. `lsof`'s first `txt`
# entry is the image actually mapped, which is the question being asked.
RUNNING_IMAGE=$(lsof -p "$DAEMON_PID" -a -d txt 2>/dev/null | awk 'NR==2 {print $NF}')
[ "$RUNNING_IMAGE" = "$TMP/juancoded-v2" ] \
  || fail "pid $DAEMON_PID is running $RUNNING_IMAGE, not the new binary"
echo "1. same pid $DAEMON_PID, now running $RUNNING_IMAGE"

kill -0 "$CHILD_PID" 2>/dev/null || fail "the CLI was killed by the swap"
STILL_OURS=$(ps -Ao pid,ppid | awk -v c="$CHILD_PID" -v p="$DAEMON_PID" '$1==c && $2==p {print "yes"}')
[ "$STILL_OURS" = "yes" ] || fail "pid $CHILD_PID is no longer a child of the daemon"
echo "2. same CLI pid $CHILD_PID, still under $DAEMON_PID"

AFTER=$(node "$TMP/ws.mjs" attach "$PORT" "$SESSION" after-swap) || fail "could not reattach"
STATUS=$(echo "$AFTER" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).status))')
STAMP_AFTER=$(echo "$AFTER" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).buildStampMs))')
[ "$STATUS" = "running" ] || fail "the session came back as $STATUS, not running"
echo "3. the session reads $STATUS and answered new input; no --resume was needed"
[ "$STAMP_BEFORE" != "$STAMP_AFTER" ] && echo "   (build stamp moved $STAMP_BEFORE -> $STAMP_AFTER)"

# The attach above replayed the whole history, so one string holds both sides of the
# swap. Order matters as much as presence: a gap would show as the later marker
# arriving without the earlier one behind it.
echo "$AFTER" | grep -q 'FAKE-CLI-READY' || fail "the history lost the session's first line"
echo "$AFTER" | grep -q 'echo:before-swap' || fail "the history lost what was said before the swap"
echo "$AFTER" | grep -q 'echo:after-swap' || fail "the CLI did not answer after the swap"
echo "4. scrollback spans the swap: READY, before-swap and after-swap are all in it"

say "and again, this time mid-response"
# The question the first four do not ask: not "did the session survive", but "was a
# single byte of it lost". The CLI is put in the middle of a long answer and the swap
# happens underneath it; every line it printed has to be in the history afterwards,
# in order and exactly once. A flush that missed the last chunk before the exec, or a
# reader that kept pulling bytes into a buffer the exec threw away, shows up here as
# a hole in the middle of a sequence.
#
# Waited for by CONTENT, never by the clock. Each `sleep` in that shell loop is a
# fork+exec, which costs a quarter of a second on this machine under load, so a fixed
# wait long enough on a quiet Mac expires mid-answer on a busy one — and an answer
# still being written reads exactly like an answer that was lost.
LINES=40
node "$TMP/ws.mjs" attach "$PORT" "$SESSION" "stream:$LINES" >/dev/null 2>&1 &
STREAMER=$!

# Swap once the answer is demonstrably under way, so the exec lands mid-stream rather
# than before it starts.
for _ in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$PORT/api/sessions/$SESSION/scrollback" 2>/dev/null \
    | grep -q 'line-3' && break
  sleep 0.5
done
lsof -p "$DAEMON_PID" -a -d txt 2>/dev/null | awk 'NR==2 {print "   swapping while it talks; currently " $NF}'
curl -sS -m 20 -X POST "http://127.0.0.1:$PORT/api/reexec" \
  -H 'content-type: application/json' \
  -d "{\"binary\":\"$TMP/juancoded-v1\"}" >/dev/null 2>&1 || true
kill "$STREAMER" 2>/dev/null
wait "$STREAMER" 2>/dev/null || true

for _ in $(seq 1 80); do
  curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break
  sleep 0.25
done
curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null || fail "the daemon never came back"
kill -0 "$CHILD_PID" 2>/dev/null || fail "the mid-response swap killed the CLI"

# The adopted pty has to keep delivering the rest of the answer, so wait for the CLI
# to say it is finished rather than for a number of seconds to pass.
for _ in $(seq 1 240); do
  curl -fsS "http://127.0.0.1:$PORT/api/sessions/$SESSION/scrollback" 2>/dev/null \
    | grep -q 'stream-done' && break
  sleep 0.5
done
FINAL=$(node "$TMP/ws.mjs" attach "$PORT" "$SESSION") || fail "could not reattach after the second swap"
echo "$FINAL" | node -e '
let s = "";
process.stdin.on("data", (d) => (s += d)).on("end", () => {
  const seen = JSON.parse(s).seen;
  const want = Number(process.argv[1]);
  const got = [...seen.matchAll(/line-(\d+)/g)].map((m) => Number(m[1]));
  const missing = [];
  for (let i = 1; i <= want; i++) if (!got.includes(i)) missing.push(i);
  if (!seen.includes("stream-done")) {
    console.error(`the CLI never finished the answer it was in the middle of; it reached line ${Math.max(0, ...got)} of ${want}`);
    process.exit(1);
  }
  if (missing.length) {
    console.error(`the history has a hole: ${missing.length} of ${want} lines are gone (${missing.slice(0, 12).join(",")}...)`);
    console.error(`  tail: ${JSON.stringify(seen.slice(-300))}`);
    process.exit(1);
  }
  const ordered = got.filter((n, i) => i === 0 || n >= got[i - 1]);
  if (ordered.length !== got.length) {
    console.error("the lines came back out of order, so two histories were spliced");
    process.exit(1);
  }
  console.log(`5. all ${want} lines of a mid-response answer survived the swap, in order, plus its stream-done`);
});
' "$LINES" || fail "the mid-response swap lost output"

say "and the stop ladder still ends an adopted child"
# The other half of "nothing downstream can tell an adopted pty from a spawned one":
# the handle has to END like one too. The ladder lives on `PtyHandle` and not on the
# ends underneath it, so this is checking that the adopted end did not quietly break
# the one path that reaps a CLI and its helpers.
node -e '
const ws = new WebSocket(`ws://127.0.0.1:${process.argv[1]}/ws`);
ws.onopen = () => {
  ws.send(JSON.stringify({ type: "kill", sessionId: process.argv[2] }));
  setTimeout(() => { ws.close(); process.exit(0); }, 1500);
};
' "$PORT" "$SESSION"
for _ in $(seq 1 30); do
  kill -0 "$CHILD_PID" 2>/dev/null || break
  sleep 0.3
done
kill -0 "$CHILD_PID" 2>/dev/null && fail "killing an adopted session left its CLI running"
echo "6. the adopted CLI was reaped through the ordinary stop ladder"

say "PASS"
