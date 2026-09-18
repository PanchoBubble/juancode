#!/bin/bash
# Stand-in for `gh` while the conformance suite runs (JUANCODE_GH_BIN).
#
# Two behaviours, chosen by where it is run.
#
# Anywhere on this machine: fail, loudly, the way an unauthenticated `gh` fails. A
# test run must not reach GitHub — no token, no network, no rate limit, and no chance
# of touching a real repository. Every probe in both cores tolerates exactly this,
# so the tracked-PR watch list stays whatever the scenario put in it.
#
# Inside a directory carrying `.gh-fixtures/`: serve the recorded JSON in it. That
# directory is written by the suite's own workspace (`makeWorkspace`), so the only
# place this answers is a temp directory the run created for the purpose. The reason
# the switch is the CWD and not a variable is that both behaviours have to be live in
# ONE core boot: 14-tracked-prs asserts a poll that finds nothing, and 45-github
# asserts a PR list that is really there.
#
# The fixtures are the SHAPES gh emits, recorded from GhTests.swift and the Rust
# port's own tests rather than invented here, because a fixture that does not look
# like gh tests the parser against itself.

fixtures="$PWD/.gh-fixtures"

fail() {
  echo "fake-gh: refusing to reach GitHub from a conformance run ($*)" >&2
  exit 1
}

serve() {
  # A fixture the run did not record is a shape nobody asked for: fail rather than
  # answer with an empty list, which a caller would read as a real "none".
  [ -f "$fixtures/$1" ] || fail "$@"
  cat "$fixtures/$1"
  exit 0
}

[ -d "$fixtures" ] || fail "$@"

case "$1 $2" in
  "pr list")
    # `--head <branch>` is the single-branch lookup, a different answer from the page.
    case " $* " in
      *" --head "*) serve pr-for-branch.json ;;
      *" --search "*) serve pr-search.json ;;
      *) serve pr-list.json ;;
    esac
    ;;
  "pr view") serve pr-activity.json ;;
  "pr checks") serve pr-checks.json ;;
  "repo view") serve repo-nwo.txt ;;
  "run view") serve run-log.txt ;;
  "api user") serve viewer.txt ;;
  "api graphql")
    # The two GraphQL calls are told apart by what they ask for, which is also the
    # only thing that distinguishes them on the wire.
    case " $* " in
      *"pullRequests(states: OPEN"*) serve thread-counts.json ;;
      *"pullRequest(number:"*) serve conversation.json ;;
      *) fail "$@" ;;
    esac
    ;;
  *) fail "$@" ;;
esac
