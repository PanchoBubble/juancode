#!/usr/bin/env bash
# Install, arm, inspect and remove the LaunchAgent that runs the daily worktree
# sweep (scripts/worktree-sweep.mjs).
#
# WHAT THE JOB DOES. Once a day at a quiet hour it looks at every worktree of
# this checkout and removes the ones that are more than two days old and have
# nothing in them worth keeping: no uncommitted files, no unpushed commits, no
# open PR, nothing running inside them. Every run appends to
# ~/.juancode/logs/worktree-sweep.log whether it removed anything or not.
#
# IT IS INSTALLED DISARMED. `install` writes a plist whose command line is a DRY
# RUN: it walks, it logs what it would have removed, it removes nothing. Arming
# it is a second, separate decision — `arm` — so that nobody discovers this
# script is real by finding a worktree missing.
#
#   worktree-sweeper-agent.sh install    # daily DRY RUN, logs only
#   worktree-sweeper-agent.sh arm        # switch the daily run to --apply
#   worktree-sweeper-agent.sh disarm     # back to dry run, job stays installed
#   worktree-sweeper-agent.sh run        # run it now, in this terminal, dry
#   worktree-sweeper-agent.sh run --apply
#   worktree-sweeper-agent.sh status
#   worktree-sweeper-agent.sh uninstall
#   worktree-sweeper-agent.sh log
#   worktree-sweeper-agent.sh render     # write + lint the plist, load nothing
#
# RunAtLoad is false on purpose. A login is not the moment to start deleting
# things — you have just sat down, and the first thing you would see is a tree
# you wanted being gone. StartCalendarInterval only.
#
# THE PLIST NAMES ONE CHECKOUT, like com.juanone.juancoded does, and it must be
# the MAIN one: a sweep pinned to a worktree would be pinned to something it is
# itself allowed to delete. `install` refuses to run from a worktree.
#
# Env:
#   JUANCODE_SWEEPER_PLIST   write the plist somewhere else (testing)
#   JUANCODE_SWEEP_HOUR      hour of the daily run (default 4)
#   JUANCODE_SWEEP_MINUTE    minute of the daily run (default 30)
#   JUANCODE_SWEEP_DAYS      age floor in days (default 2)
#   JUANCODE_SWEEPER_ARM_CONFIRMED=1
#                            stand in for the interactive "arm?" answer, for a
#                            caller that asked the human itself. The Settings →
#                            Worktrees pane sets it, and only after it has shown a
#                            dry run and put the same question in a dialog. It
#                            replaces the prompt, never the decision: nothing else
#                            about arming changes, and an unset variable still
#                            means a terminal has to answer.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
SWEEP="$ROOT/scripts/worktree-sweep.mjs"

LABEL="com.juanone.juancode-sweeper"
PLIST="${JUANCODE_SWEEPER_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
LOG_DIR="$HOME/.juancode/logs"
OUT_LOG="$LOG_DIR/worktree-sweep.launchd.log"
ERR_LOG="$LOG_DIR/worktree-sweep.launchd.error.log"
RUN_LOG="$LOG_DIR/worktree-sweep.log"
HOUR="${JUANCODE_SWEEP_HOUR:-4}"
MINUTE="${JUANCODE_SWEEP_MINUTE:-30}"
DAYS="${JUANCODE_SWEEP_DAYS:-2}"
DOMAIN="gui/$(id -u)"
TARGET="$DOMAIN/$LABEL"

say()  { printf 'worktree-sweeper: %s\n' "$*" >&2; }
warn() { printf 'worktree-sweeper: %s\n' "$*" >&2; }

loaded() { launchctl print "$TARGET" >/dev/null 2>&1; }

# launchd's PATH has no node in it, and it is not going to grow one, so the
# interpreter is resolved here and pinned into the plist. `status` says so when
# the pinned binary has since moved (a Homebrew node upgrade relocates the
# Cellar path behind the symlink, but /opt/homebrew/bin/node itself survives).
node_bin() { command -v node || true; }

installed_mode() {
  [ -f "$PLIST" ] || return 0
  if /usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST" 2>/dev/null | grep -q -- '--apply'; then
    printf 'ARMED'
  else
    printf 'dry-run'
  fi
}

installed_root() {
  [ -f "$PLIST" ] || return 0
  /usr/libexec/PlistBuddy -c 'Print :WorkingDirectory' "$PLIST" 2>/dev/null || true
}

# The age floor baked into the plist, which is not necessarily $DAYS: the job keeps
# whatever it was installed with until it is rewritten.
installed_days() {
  [ -f "$PLIST" ] || return 0
  /usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST" 2>/dev/null \
    | sed -n 's/^ *--days=//p' | head -1
}

# $1: "apply" or "dry"
write_plist() {
  local mode="$1" node apply_arg=""
  node="$(node_bin)"
  [ -n "$node" ] || { warn "no node on PATH to pin into the plist"; return 1; }
  [ "$mode" = apply ] && apply_arg=$'\n\t\t<string>--apply</string>'

  mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"
  cat > "$PLIST.tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<!-- An absolute node: launchd's PATH has none. --root is pinned too, because
	     the job's WorkingDirectory is not something to rely on for a script whose
	     job is deleting directories. Without --apply this is a DRY RUN: it writes
	     $RUN_LOG and removes nothing. -->
	<key>ProgramArguments</key>
	<array>
		<string>$node</string>
		<string>$SWEEP</string>
		<string>--root=$ROOT</string>
		<string>--days=$DAYS</string>$apply_arg
	</array>
	<key>WorkingDirectory</key>
	<string>$ROOT</string>
	<!-- FALSE, deliberately. A login is not the moment to start deleting things. -->
	<key>RunAtLoad</key>
	<false/>
	<!-- Once a day, at an hour nobody is working. If the Mac is asleep then,
	     launchd runs it at the next wake — which is the behaviour we want: a
	     missed sweep is a sweep, late. -->
	<key>StartCalendarInterval</key>
	<dict>
		<key>Hour</key>
		<integer>$HOUR</integer>
		<key>Minute</key>
		<integer>$MINUTE</integer>
	</dict>
	<!-- It walks a lot of directories and the user may be at the machine. -->
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityIO</key>
	<true/>
	<key>Nice</key>
	<integer>5</integer>
	<key>StandardOutPath</key>
	<string>$OUT_LOG</string>
	<key>StandardErrorPath</key>
	<string>$ERR_LOG</string>
</dict>
</plist>
PLIST
  mv -f "$PLIST.tmp" "$PLIST"
  plutil -lint "$PLIST" >/dev/null
}

bootstrap_job() {
  launchctl bootout "$TARGET" >/dev/null 2>&1 || true
  launchctl bootstrap "$DOMAIN" "$PLIST"
}

require_main_checkout() {
  # A worktree's .git is a FILE. Pinning the sweep to a worktree would pin it to
  # a directory it is itself a candidate to delete.
  if [ -f "$ROOT/.git" ]; then
    warn "$ROOT is a worktree (.git is a file)."
    warn "Install from the main checkout — the job must not be pinned to a tree it can sweep."
    return 1
  fi
}

cmd_install() {
  require_main_checkout
  [ -f "$SWEEP" ] || { warn "no sweeper at $SWEEP"; return 1; }
  local mode=dry
  [ "${1:-}" = "--apply" ] && mode=apply
  if [ "$mode" = apply ]; then
    confirm_arming || return 0
  fi
  write_plist "$mode"
  say "wrote $PLIST ($(installed_mode))"
  bootstrap_job
  say "bootstrapped $TARGET — next run ${HOUR}:$(printf '%02d' "$MINUTE"), RunAtLoad is false"
  [ "$mode" = dry ] && say "it is DISARMED: it will log what it would remove. \`$0 arm\` to switch it on."
  cmd_status
}

confirm_arming() {
  warn "=============================================================="
  warn "ARMING MAKES THE DAILY JOB DELETE WORKTREES."
  warn "=============================================================="
  warn "Read a dry run first:  $0 run"
  warn "and the log:           $RUN_LOG"
  if [ "${JUANCODE_SWEEPER_ARM_CONFIRMED:-}" = 1 ]; then
    say "JUANCODE_SWEEPER_ARM_CONFIRMED=1: the caller has already asked."
    return 0
  fi
  [ -t 0 ] || { warn "no terminal to ask on; not arming."; return 1; }
  local answer
  read -r -p "worktree-sweeper: arm the daily sweep of $ROOT? [y/N] " answer >&2 || answer=""
  case "$answer" in y|Y) return 0 ;; *) say "left it disarmed"; return 1 ;; esac
}

cmd_arm() {
  [ -f "$PLIST" ] || { warn "not installed. \`$0 install\` first."; return 1; }
  confirm_arming || return 0
  write_plist apply
  bootstrap_job
  say "ARMED. \`$0 disarm\` puts it back to a dry run."
  cmd_status
}

cmd_disarm() {
  [ -f "$PLIST" ] || { warn "not installed; nothing to disarm"; return 0; }
  write_plist dry
  bootstrap_job
  say "disarmed: the daily run is a dry run again"
  cmd_status
}

cmd_uninstall() {
  launchctl bootout "$TARGET" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  say "booted out $TARGET and removed $PLIST"
  say "nothing prunes worktrees again; \`pnpm sweep\` still works by hand"
}

# Every argument after `run` goes to the sweep verbatim, so a caller can ask for
# `--json` or `--no-fetch` without knowing where node or the checkout are. The
# sweep's own default is a dry run: only an explicit --apply here removes anything.
cmd_run() {
  shift || true
  local armed=""
  for a in "$@"; do [ "$a" = "--apply" ] && armed=" (ARMED)"; done
  say "running the sweep now$armed"
  "$(node_bin)" "$SWEEP" "--root=$ROOT" "--days=$DAYS" "$@"
}

cmd_status() {
  if [ ! -f "$PLIST" ]; then
    say "NOT installed (no $PLIST)"
    say "  \`$0 install\` writes it, disarmed. Nothing prunes worktrees until then."
  else
    say "installed: $PLIST"
    say "  mode:     $(installed_mode)"
    local where; where="$(installed_root)"
    if [ -n "$where" ] && [ "$where" != "$ROOT" ]; then
      warn "  it sweeps ANOTHER CHECKOUT: $where (you are in $ROOT)"
    else
      say "  checkout: ${where:-unknown} (this one)"
    fi
    say "  days:     $(installed_days)"
    say "  schedule: daily at ${HOUR}:$(printf '%02d' "$MINUTE"), RunAtLoad false"
    local pinned
    pinned="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST" 2>/dev/null || true)"
    [ -x "$pinned" ] || warn "  the pinned interpreter is gone: $pinned — reinstall"
  fi
  if loaded; then say "loaded in $DOMAIN"; else say "not loaded in $DOMAIN"; fi
  say "run log: $RUN_LOG"
  [ -f "$RUN_LOG" ] && tail -1 "$RUN_LOG" | sed 's/^/    /' >&2
  return 0
}

# Write and lint the plist without going near launchd, so what the job would run
# can be read before anything is bootstrapped.
cmd_render() {
  write_plist "${1:-dry}"
  say "wrote $PLIST (not loaded)"
  cat "$PLIST"
}

cmd_log() { tail -n "${2:-60}" "$RUN_LOG"; }

case "${1:-status}" in
  install)   cmd_install "${2:-}" ;;
  arm)       cmd_arm ;;
  disarm)    cmd_disarm ;;
  uninstall) cmd_uninstall ;;
  run)       cmd_run "$@" ;;
  render)    cmd_render "${2:-dry}" ;;
  status)    cmd_status ;;
  log)       cmd_log "$@" ;;
  *) warn "unknown command: $1 (want: install|arm|disarm|uninstall|run|render|status|log)"; exit 2 ;;
esac
