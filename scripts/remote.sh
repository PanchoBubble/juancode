#!/usr/bin/env bash
# Drive juancode on another Mac from this one. Sessions run THERE: its CLIs, its logins,
# its subscriptions, its repos. This Mac only shows and steers them.
#
#   scripts/remote.sh <ssh-host> [local-port]     # also `pnpm remote <ssh-host>`
#
# The other Mac needs Remote Login on (System Settings → General → Sharing) and its
# daemon running (`pnpm daemon:agent install` in its checkout). The daemon listens on
# loopback only and has no auth, so it is reached through an SSH tunnel, never the LAN.
#
# Opens a second juancode window titled "juancode @ <host>", with its own relay port and
# data dir so it never mixes with this Mac's sessions. Quit it and the tunnel closes.
set -euo pipefail

HOST="${1:?usage: scripts/remote.sh <ssh-host> [local-port]}"
LPORT="${2:-4391}"
RPORT="${JUANCODE_REMOTE_DAEMON_PORT:-4290}"
APP="${JUANCODE_APP:-$HOME/Applications/juancode.app}/Contents/MacOS/juancode"
SOCK="${TMPDIR:-/tmp}/juancode-remote-$LPORT.sock"

say() { printf 'juancode remote: %s\n' "$*" >&2; }

[[ -x $APP ]] || { say "no app at $APP — run \`make install\` (or set JUANCODE_APP)"; exit 1; }
for p in "$LPORT" "$((LPORT + 1))"; do
  if nc -z 127.0.0.1 "$p" 2>/dev/null; then say "port $p is taken; pass another local port"; exit 1; fi
done

# -f backgrounds only after auth, so password / key prompts still work in this terminal.
ssh -fNM -S "$SOCK" -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
  -L "$LPORT:127.0.0.1:$RPORT" "$HOST"
trap 'ssh -S "$SOCK" -O exit "$HOST" 2>/dev/null || true' EXIT INT TERM

if ! curl -sf -m 5 "http://127.0.0.1:$LPORT/health" >/dev/null; then
  say "tunnel is up but no juancoded answers on $HOST:$RPORT — start it there (\`pnpm daemon:agent install\`)"
  exit 1
fi

say "connected to $HOST; opening juancode @ $HOST (quit it to close the tunnel)"
JUANCODE_RUST_CORE_URL="http://127.0.0.1:$LPORT" \
JUANCODE_PORT="$((LPORT + 1))" \
JUANCODE_DATA_DIR="$HOME/.juancode/remote/$HOST" \
JUANCODE_REMOTE_NAME="$HOST" \
  "$APP"
