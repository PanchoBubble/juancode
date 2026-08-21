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
#   ECHO <text>      print text and a CRLF
#   BUSY             print the working footer both real CLIs paint while a turn runs
#   PROMPT           print a yes/no question on the bottom row (a waiting-input screen)
#   CLEAR            erase the screen and home the cursor (ends a busy turn)
#   ALT              switch to the alternate screen buffer and print a line
#   MAIN             switch back to the main buffer
#   HIDE / SHOW      hide / show the cursor
#   MOVE <row> <col> position the cursor (1-based)
#   TITLE <text>     set an OSC 2 window title (how a real CLI names its session)
#   EXIT <code>      exit with that status
#
# Provider args (--session-id, --resume, --model, permission flags) are ignored on
# purpose: the harness asserts the wire, not the argv.

# No echo: keystrokes the harness sends must not appear in the golden screen.
stty -echo 2>/dev/null

printf 'fake-agent ready\r\n'

while IFS= read -r line; do
  cmd=${line%% *}
  arg=${line#"$cmd"}
  arg=${arg# }
  case "$cmd" in
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
  EXIT)
    exit "${arg:-0}"
    ;;
  *)
    printf 'unknown command\r\n'
    ;;
  esac
done

exit 0
