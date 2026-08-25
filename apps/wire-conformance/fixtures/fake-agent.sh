#!/bin/bash
# Deterministic stand-in for a real agent CLI, used as JUANCODE_CLAUDE_BIN /
# JUANCODE_CODEX_BIN while the conformance suite runs.
#
# Why not the real thing: a golden transcript has to be reproducible, and
# `claude`/`codex` need auth, a network, and paint whatever their current build
# paints. This reads one command per line off the pty and prints exactly the bytes
# the scenario asked for, so every screen frame and activity edge is scripted.
#
# The command vocabulary IS part of the spec (spec/v1/scenarios/*.json drive it):
#   READY            banner, printed on start without being asked
#   ARGS             print the argv this process was spawned with
#   ECHO <text>      print text and a CRLF
#   BUSY             print the working footer both real CLIs paint while a turn runs
#   PROMPT           print a yes/no question on the bottom row (a waiting-input screen)
#   CLEAR            erase the screen and home the cursor (ends a busy turn)
#   ALT              switch to the alternate screen buffer and print a line
#   MAIN             switch back to the main buffer
#   HIDE / SHOW      hide / show the cursor
#   MOVE <row> <col> position the cursor (1-based)
#   TITLE <text>     set an OSC 2 window title (how a real CLI names its session)
#   TRANSCRIPT <text> append a turn to claude's own jsonl (the transcript plane's source)
#   EXIT <code>      exit with that status
#
# Provider args (--session-id, --resume, --model, permission flags) do not change
# what this prints: the harness asserts the wire, not the argv. The one exception is
# `ARGS`, which echoes them back, because a create's pinned model and a fresh restart
# are only visible in the argv the core chose.

# Echo stays ON, unlike an ordinary script's instinct: a real CLI paints what it is
# sent into its input box, and that painting is the only thing a delivery engine can
# verify a paste against before it sends the submitting Enter. A stand-in that showed
# nothing would make a seeded prompt undeliverable by construction. The scenarios
# assert with $contains / $some, so an echoed command row alongside the answer does
# not change what any of them mean.
stty echo 2>/dev/null

ESC=$(printf '\033')

ARGV="$*"

# Where claude would keep this conversation's own jsonl, and the file itself.
#
# The transcript plane does not read the pty: it reads the CLI's own store. So a
# stand-in that only paints a screen leaves that plane with nothing to read, and the
# `transcript` scenario would be asserting an empty history against an empty file.
# This writes what claude writes, into the projects directory the harness already
# points every booted core at (never a developer's real ~/.claude).
#
# The file is created empty on start, before any command arrives, because binding is
# what costs: a source that cannot find the file backs off for BIND_RETRY seconds, and
# the first bind attempt happens on the spawn banner. An empty file binds and yields no
# events, so every OTHER scenario is unaffected: nothing is read because nothing was
# written.
SESSION_ID=""
prev=""
for a in "$@"; do
  [ "$prev" = "--session-id" ] && SESSION_ID=$a
  prev=$a
done
TRANSCRIPT_FILE=""
TRANSCRIPT_TURN=0
if [ -n "${JUANCODE_CLAUDE_PROJECTS_DIR:-}" ] && [ -n "$SESSION_ID" ]; then
  # claude's own directory rule: every character outside [A-Za-z0-9] becomes a dash.
  slug=$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')
  mkdir -p "$JUANCODE_CLAUDE_PROJECTS_DIR/$slug"
  TRANSCRIPT_FILE="$JUANCODE_CLAUDE_PROJECTS_DIR/$slug/$SESSION_ID.jsonl"
  # Append-mode create: a resumed conversation keeps the history it already had.
  : >>"$TRANSCRIPT_FILE"
fi

printf 'fake-agent ready\r\n'

while IFS= read -r line; do
  # Bracketed-paste markers are consumed, not run: a real CLI reads them as "this is
  # a paste" and keeps the text, so a stand-in that treated ESC[200~ as part of the
  # command would turn every pasted prompt into an unknown one.
  line=${line//"${ESC}[200~"/}
  line=${line//"${ESC}[201~"/}
  cmd=${line%% *}
  arg=${line#"$cmd"}
  arg=${arg# }
  case "$cmd" in
  ARGS)
    printf 'argv: %s\r\n' "$ARGV"
    ;;
  ECHO)
    printf '%s\r\n' "$arg"
    ;;
  BUSY)
    # "esc to interrupt" is the wording-independent working marker the activity
    # detector gates on; while it stays on screen the session reads as busy.
    printf 'working... esc to interrupt\r\n'
    ;;
  PROMPT)
    # Bottom row: prose prompt markers are only trusted in the footer region.
    printf '\033[999;1HDo you want to proceed? (y/n)'
    ;;
  CLEAR)
    printf '\033[2J\033[H'
    ;;
  ALT)
    printf '\033[?1049h\033[Halt buffer\r\n'
    ;;
  MAIN)
    printf '\033[?1049l'
    ;;
  HIDE)
    printf '\033[?25l'
    ;;
  SHOW)
    printf '\033[?25h'
    ;;
  MOVE)
    row=${arg%% *}
    col=${arg#* }
    printf '\033[%s;%sH' "${row:-1}" "${col:-1}"
    ;;
  TITLE)
    # A CLI naming its own session. The core adopts this as the session title and
    # broadcasts the new meta, without anyone having asked it to.
    printf '\033]2;%s\007' "$arg"
    ;;
  TRANSCRIPT)
    # One turn as claude records it: the prompt line, then the assistant line that
    # answers it. Three events come out of the pair (turnStart, step, assistant), and
    # a second TRANSCRIPT closes the open turn first, so the seq numbers a scenario
    # asserts on are the source's, not this script's.
    #
    # <text> is embedded in JSON unquoted, so scenarios keep it to plain words.
    if [ -n "$TRANSCRIPT_FILE" ]; then
      TRANSCRIPT_TURN=$((TRANSCRIPT_TURN + 1))
      at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      printf '{"type":"user","timestamp":"%s","promptId":"turn-%s","message":{"role":"user","content":"%s"}}\n' \
        "$at" "$TRANSCRIPT_TURN" "$arg" >>"$TRANSCRIPT_FILE"
      printf '{"type":"assistant","timestamp":"%s","requestId":"req-%s","message":{"role":"assistant","model":"fake-model","content":[{"type":"text","text":"answered %s"}]}}\n' \
        "$at" "$TRANSCRIPT_TURN" "$arg" >>"$TRANSCRIPT_FILE"
    fi
    # Printed AFTER the file is written: the output is what marks the session dirty,
    # and a pump that polled first would read a file the turn has not reached yet.
    printf 'transcript %s\r\n' "$arg"
    ;;
  EXIT)
    exit "${arg:-0}"
    ;;
  *)
    printf 'unknown command\r\n'
    ;;
  esac
done

exit 0
