# Porting queue delivery to the Rust core

Written for `juancode-52e8.8` while landing `juancode-1esi` (the queue wire surface).
This core can now hold a queue and push authoritative snapshots of it; nothing here
types a queued message into a pty, which is why `serverInfo` does not advertise the
`queue` capability. This is the reading of the Swift engine that the port needs, and
the parts of it that should not be copied as they stand.

Source read: `Session.deliverQueued` / `flushQueue` / `kickQueue` and their
neighbours in `apps/native/Sources/JuancodeCore/Session.swift`, plus
`InitialPromptDelivery` and `MessageQueue.swift`.

## What the Swift engine does

1. A queue flush fires on a real transition **into** idle (a turn boundary), or on
   `kickQueue` when a message is added to an already idle session. Never on a timer.
2. One message per pass. It peeks the head, delivers it, and pops it only once it
   verifiably submitted. The agent finishing that turn produces the next idle edge,
   which delivers the next message. Order is insertion order.
3. Delivery is paste-then-verified-Enter, not write-and-hope:
   - sample the input-box footer **before** pasting,
   - write the payload as a bracketed paste (`ESC[200~ … ESC[201~`) with no CR,
   - poll until the footer says the paste landed,
   - settle 200 ms so the CR cannot be swallowed by a still-open paste,
   - write `\r`, poll until the submit is confirmed, up to three attempts.
4. A stalled delivery is left queued and retried on the next idle edge rather than
   spun on.

## What it must observe to believe a paste landed

The land check is the whole engine. It compares two footer snapshots, where a
snapshot is the normalized text of the bottom 16 rows **plus the grid it was
rendered at**:

- **same grid.** A resize re-frames the bottom-rows window, so every row in it
  appears to change. Without the `(cols, rows)` equality guard the boot-time grid
  nudge alone reads as "the paste landed".
- **text changed** since the pre-paste sample. This is what stops a delivery being
  credited to text that was already on those rows: the user typed the message
  earlier, the agent quoted it back, or a previous failed delivery left a copy in the
  transcript.
- **and the footer holds the payload**, by any of three signatures: the head (first
  non-empty line, normalized, 24 chars), the tail (last non-empty line, same
  treatment, because a tall paste pushes its head above the footer), or Claude's
  collapsed-paste chip, matched as the literal string `pasted text`, because a large
  or multi-line paste is never echoed as text at all.

Two more preconditions matter as much as the match:

- **activity must not be busy before pasting.** A session that is genuinely working
  is not ours to paste into, and the pre-paste sample has to be taken before the
  paste makes the CLI repaint its footer. Reading that repaint as "the agent took the
  turn" is what skipped the Enter and left messages unsent.
- **the paste is remembered, so a retry does not re-paste.** `pastedQueuedId` records
  that this message's text is already sitting in the box; the retry then sends Enter
  again. Re-pasting is what stacked duplicate copies of a message.

Submission is confirmed by either edge: activity went busy, or the payload left the
footer.

## What the daemon cannot observe

Nothing in this is an acknowledgement. There is no protocol between us and the CLI:
the engine reads a rendered picture of another program's TUI and infers intent from
it. Specifically, from the daemon side there is no way to see

- the CLI's own input buffer, only what it painted,
- whether a CR was accepted as a submit or swallowed as a literal newline inside an
  open bracketed paste, except by waiting to see what happens next,
- whether a paste that produced no visible change was dropped or is merely not
  painted yet,
- how a given provider renders a paste. Claude collapses to a chip, and codex and
  opencode do not; the three signatures above are a Claude-shaped heuristic that the
  port should treat as per-provider from the start rather than discovering later.

That is unchanged by the language. It is the reason the honest goal is
"never deliver twice", not "always deliver".

## Is the land check easier or harder in the daemon?

**The read is easier.** There is exactly one grid per session here, owned behind the
`terminal` service's lock and fed only by that session's pty pump, and `Snapshot` is
a value type. The Swift side has two parsers on one stream (a headless model plus the
GUI terminal view) and a process-wide parse lock with a documented residual race
(juancode-9goj); a Rust land check cannot read a half-applied grid and needs no lock
of its own. `Snapshot::bottom_text(n)` is already the footer window, and the snapshot
carries `cols`/`rows`, so both halves of the Swift `FooterSnapshot` exist today.

**What is being read is less stable.** The grid is client-arbitrated: any client that
wins the grid can resize under a delivery in flight, and every boot nudges rows-1
then rows. So the grid-equality guard is more load-bearing here than in Swift, not
less, and the port must additionally not treat a *denied* resize as a change.

**One genuine advantage over Swift, and it is the one to build on.** Every write to a
session funnels through the `session.input` around chain
(`SessionRegistry::input`). The delivery engine can therefore be the only writer for
the length of a delivery window: an around-chain guard refuses or defers a client's
input while a paste is unverified, so a second writer cannot make the footer change
and get credited as our landing. In the Swift app the desktop and every remote client
write the pty directly and no such window exists. This is also exactly where the
claim boundary that `juancode-52e8.8` asks for belongs, and the registry does not
have to know any policy exists for it to work.

## Do not port the current land check verbatim

A sibling change under `juancode-g4id` is correcting it right now: `deliverQueued`
re-pastes a message the child already received when the land check misses under load.
Porting today would port a design being fixed as it is read.

The structural fix the port should start from, rather than inherit: make the claim
explicit and durable instead of inferring it from the screen. Give each queue
occurrence a claim (its own id already exists; a `claimed_at` column is the missing
half), and let the screen check decide only whether to press Enter, never whether to
paste again. Once an occurrence is claimed it is never re-pasted. That turns a
duplicate-delivery bug into a stuck-message bug that a snapshot can show a human, and
a human can press Enter. It is the trade the Swift side is converging on anyway.

## Port checklist

1. `session.input` around-chain guard: the claim boundary and the exclusive write
   window, in one plugin. Nothing else can be correct without it.
2. `claimed_at` on the queue row, plus `claim`/`release` on the store, so a claim
   survives a restart and a restart does not re-paste.
3. Pure text helpers, ported with their unit tests, since they are the part that
   drifts as the CLIs change their TUIs: normalize, head signature, tail signature,
   region-contains, collapsed-paste chip. Per-provider from the start.
4. Bracketed paste as a writer on the input chain, not a raw `input` call, so it is
   inside the exclusive window.
5. The flush itself: fire on the registry's busy to idle transition and on a queue
   change for an idle session, one message per pass, and emit `QueueChanged` when an
   occurrence is claimed and again when it is removed, so watchers see the queue
   drain without inferring anything from activity events.
6. Only then add `queue` to `CAPABILITIES`, and land it in the same change as
   delivery. Scenario 10 already passes against this wire surface with the capability
   temporarily switched on (measured five times out of five, 2026-08-22), so the
   surface is not what is holding the capability back.
