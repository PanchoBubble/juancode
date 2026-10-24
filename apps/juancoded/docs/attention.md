# Session attention inbox

`juancoded` owns the inbox and persists it in its existing SQLite database. Native,
Oracle and Telegram read the same records. This is inspired by the daemon-owned
inbox in [tuios](https://github.com/Gaurav-Gosain/tuios/blob/main/docs/AGENT_STATE.md#the-inbox);
no upstream source code was copied.

Clients feature-detect the `attention` capability, then send `subscribeAttention`.
The reply and each update are full replacements:

```json
{
  "type": "attention",
  "items": [
    {
      "id": "occurrence-uuid",
      "sessionId": "session-uuid",
      "kind": "waiting",
      "createdAt": 1792870000000,
      "updatedAt": 1792870000000,
      "acknowledged": false,
      "resolved": false
    }
  ]
}
```

Items are ordered by `createdAt` then `id`. Timestamps are epoch milliseconds.
Unknown future kinds should remain displayable. Missing capability, disconnection
or a failed subscribe is unavailable state, not an empty inbox. Resubscribe after
reconnect; every subscription returns a fresh full snapshot. The daemon sends
changed snapshots on the existing connection cadence (up to 80 ms).

- `waiting`: the existing detector reports `waiting_input`. Its reason is unknown;
  this does not classify the prompt as a question or approval. Repeated reports
  preserve the ID. Busy, idle, exit or dormancy resolves it.
- `completion`: a notifying transition to idle. Repeated idle reports and replay
  do not generate new items. The next notifying turn replaces the prior completion
  with a new occurrence ID; resuming alone does not erase an unread completion.
- `error`: a nonzero process exit code. Repeated exit reports preserve the ID.
  Resuming busy resolves the error. No guessed error classification from PTY text.

At most the latest record of each kind is retained per session. Resolved/read
records remain in snapshots until replaced; archive/deletion removes the session's
records. On daemon restart stale waiting is reconciled against current sessions;
read completions and their IDs survive. This is an inbox, not an event-history log.

Send `acknowledgeAttention` with `id` and an optional `requestId`. The daemon replies
with `attentionResult`, echoing `requestId`, `ok`, and `error` (null on success).
Unknown IDs fail with `attention-not-found`. A success is sent only after the
acknowledgement is persisted. Retrying the same ID is idempotent. No PTY input is
sent, and acknowledgement never means approval. Storage failures are surfaced;
unpersisted lifecycle changes are retried before publishing a snapshot.

An item is actionable when `!resolved && (kind == "waiting" || !acknowledged)`.
Waiting items therefore remain visible until the agent resumes, even if read.
Native offers counts, filters, open oldest, open session and mark read. Opening a
session does not automatically acknowledge it. Existing notifications, unread
badges and chain behavior remain independent and unchanged.

The sidecar's `attention` mirror in `native-events.ts` exposes `items`, `subscribe`
and `acknowledge`; it drops its cached book on disconnect. Oracle tools are
`oracle_attention` and `oracle_attention_acknowledge`. Telegram `/inbox` lists the
same actionable records. Existing Telegram activity notifications are preserved.

OSC status (juancode-d30) may feed this shared engine after it lands, with explicit
program record identity and provenance. Richer readiness (juancode-3nj) is separate;
this inbox never changes queue delivery, CLI environment or provider configuration.
