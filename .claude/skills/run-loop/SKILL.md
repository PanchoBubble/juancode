---
name: run-loop
description: Orchestrate a plan -> implement -> test loop over a beads epic through juancode dispatches. Use when asked to "run a loop", "drive this epic", or take a goal from plan to closed tickets with separate implementer and tester sessions. The session following it is the orchestrator; it never implements or tests itself.
---

# run-loop

You are the **orchestrator**. You turn a goal (or an existing epic) into closed bd
tickets by dispatching child sessions — a planner, then one implementer and one tester
per ticket — and reacting to their RESULT blocks. There is no workflow engine: this
skill is the loop, and your message queue is its clock.

Dispatch mechanics (preflight, provider, model-by-role table, response states) are the
**dispatch-agents** skill; the per-ticket prompt block is **dispatch-ticket**'s
"juancode conventions block". Read both; this skill only adds the loop. Pass `role` on
every dispatch — the role's duties live in `apps/oracle-mcp/src/roles.ts`, never paste them.

## Rules that keep the loop cheap and unstuck

- **Never poll.** Every dispatch passes `fromSessionId`, so each child's RESULT block
  arrives in your queue. After dispatching, **end your turn**. No sleep loops, no
  `/wait` calls, no `GET /api/sessions` checks between events.
- **Read RESULT blocks, not transcripts.** Open a child's screen or transcript only when
  its notification has no RESULT block (it crashed, exited or ignored the contract).
- **One live session per ticket.** Always pass `ticket`. A finished child stays
  running, so **delete it** once you have acted on its RESULT (see "Retire") — otherwise
  the next dispatch for that ticket is refused with 409.
- **Concurrency:** at most 2 tickets in flight unless the user gave a cap. Other
  sessions share the machine.
- **Round cap:** a ticket gets at most `N` implement→test rounds (default 3). After the
  N-th failure call `chain_ask` instead of dispatching again.

## Inputs

- A goal in free text → step 1 creates the epic.
- An epic id → skip the planner if it already has open children; otherwise plan into it.
- Optional: round cap `N`, concurrency, model overrides.

Set once: `SELF="${CLAUDE_CODE_SESSION_ID:-${CODEX_THREAD_ID:-}}"`, `PROJECT` = the main
checkout (dispatch-agents step 2), `SCRATCH` = your scratchpad. Keep the loop state —
`ticket → {round, live session id, last evidence}` — in your own context; it is small.

## Procedure

0. **Preflight** as dispatch-agents says, then read your chain notes
   (`curl -s "http://127.0.0.1:4281/api/chain-notes?fromSessionId=$SELF"`); the human's
   requests land there.

1. **Plan.** With free text, create the epic yourself
   (`sh -c 'bd create "<goal>" -t epic -p 2 --json </dev/null'`). Dispatch a planner
   (`role:"planner"`, no `ticket`, `worktree:true`, model from the planner row) whose
   prompt is the goal, the epic id, and "create the tickets with `--parent <epic>`".
   End your turn. Its RESULT lists the ticket ids.

2. **Pick ready work.**

   ```bash
   sh -c 'bd ready --parent <epic> --json 2>&1 </dev/null'
   ```

   For each ready ticket not already in flight, up to the concurrency cap, dispatch an
   implementer (step 3). If nothing is ready and nothing is in flight: go to step 7.

3. **Implement.** Claim the ticket (`bd update <id> --status in_progress`). Prompt =
   dispatch-ticket's conventions block with `<ID>` filled in, plus "Leave the ticket open
   for the tester" and, on rounds > 1, the tester's failing evidence verbatim. Dispatch
   with `role:"implementer"`, `ticket:"<id>"`, `worktree:true`, `fromSessionId:$SELF`,
   model from the role table. Record the returned `sessionId`. End your turn.

4. **On an implementer RESULT.**
   - `status: done` → check its commit is on `origin/main`
     (`git fetch -q && git branch -r --contains <sha>`), retire the implementer, then
     dispatch a tester: `role:"tester"`, `ticket:"<id>"`, `worktree:true`, prompt
     "Verify bd ticket <id> against its acceptance criteria; the implementation is
     <sha> on main." (tester row of the model table).
   - `status: question` / `blocked` → it already raised `chain_ask` or says why it
     stopped. Leave it running (it is waiting for the answer); note it and move on.
   - No RESULT → now read its screen
     (`curl -s http://127.0.0.1:4281/api/sessions/<sid>/screen`), decide, and count it
     as a failed round.

5. **On a tester RESULT.**
   - `status: done` (pass) → the tester closed the ticket; confirm with `bd show`,
     retire the tester, update the summary, back to step 2 (its dependents may be
     ready now).
   - `status: blocked` (fail) → retire the tester, increment the ticket's round. Below
     the cap: step 3 with the evidence. At the cap: step 6.

6. **Ask instead of retrying.**

   ```bash
   jq -n --arg s "$SELF" --arg q "<id> failed <N> test rounds: <one-line evidence>. How to proceed?" \
     '{sessionId:$s, question:$q, options:["Another round with this hint: ...","Split the ticket","Drop it"],
       recommended:"<your pick and why>", blocked:"<id> and its dependents"}' \
     | curl -s -m 10 -X POST http://127.0.0.1:4281/api/chain/ask \
         -H 'content-type: application/json' --data-binary @-
   ```

   Keep other tickets moving; the answer arrives as your next input.

7. **Finish.** When `bd ready --parent <epic>` is empty and nothing is in flight, list
   the epic's children (`bd list --parent <epic> --all`). All closed → close the epic.
   Anything else is blocked on a question or a dependency; say which.

## Retire a child

A child that has delivered its RESULT has nothing left to do; deleting it frees the
ticket for the next role and the machine for the next child:

```bash
curl -s -m 30 -X POST http://127.0.0.1:4281/api/sessions/delete \
  -H 'content-type: application/json' -d '{"id":"<sid>"}'
```

This removes the session's auto-created worktree too — only retire an implementer
after its commit is confirmed on `origin/main`.

## Chain summary

You own the chain headline. Post a `kind:"summary"` note whenever the state changes
(ticket dispatched, passed, failed, asked, epic done), two or three lines:

```bash
jq -n --arg from "$SELF" --arg text "<epic>: 2/5 closed; .3 implementing (round 2); .4 testing; .5 waiting on a question" \
  '{fromSessionId:$from, text:$text, kind:"summary"}' \
  | curl -s -m 10 -X POST http://127.0.0.1:4281/api/chain-notes \
      -H 'content-type: application/json' --data-binary @-
```

Use `kind:"note"` for a decision or blocker worth keeping. Re-read the chain notes
before you finish.

## End

Print: epic id, each ticket with its final state and round count, the commits that
landed, and any open questions.
