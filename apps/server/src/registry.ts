import { Session } from "./session.ts";
import { sessionDb } from "./db.ts";
import type { SpawnOptions } from "./providers.ts";
import type { ProviderId, SessionMeta } from "./protocol.ts";

type CreateListener = (session: Session) => void;

/** Holds the live (in-memory) ptys for the current server lifetime. */
class SessionRegistry {
  private readonly sessions = new Map<string, Session>();
  private readonly createListeners = new Set<CreateListener>();

  create(
    provider: ProviderId,
    cwd: string,
    cols: number,
    rows: number,
    opts?: SpawnOptions,
    worktreePath: string | null = null,
  ): Session {
    return this.track(Session.create(provider, cwd, cols, rows, opts, worktreePath));
  }

  /** Revive an exited session by resuming its prior CLI conversation. */
  resume(prev: SessionMeta, cols: number, rows: number, priorScrollback = ""): Session {
    return this.track(Session.resume(prev, cols, rows, priorScrollback));
  }

  /**
   * Flip "accept all" on a live session. There's no way to change a running CLI's
   * permission flag in place, so we kill the pty and resume the same conversation
   * (keeping the juancode id + scrollback) with the new permission level. Resolves
   * with the revived session once the old pty has exited and the new one is up.
   */
  setSkipPermissions(
    sessionId: string,
    skipPermissions: boolean,
    cols: number,
    rows: number,
  ): Promise<Session> {
    const live = this.get(sessionId);
    if (!live) throw new Error("Session is not running");
    if (live.meta.skipPermissions === skipPermissions) return Promise.resolve(live);
    if (!live.meta.cliSessionId) {
      throw new Error("Session has no captured CLI conversation to resume yet");
    }
    const next: SessionMeta = { ...live.meta, skipPermissions };
    // Snapshot the scrollback now so the revived pty carries the conversation
    // forward, with a marker before the resumed CLI repaints over it.
    const prior = sessionDb.getScrollback(sessionId);
    const seed = prior
      ? `${prior}\r\n\x1b[2m── accept-all ${skipPermissions ? "enabled" : "disabled"} ──\x1b[0m\r\n`
      : "";
    return new Promise((resolve, reject) => {
      // Resume only after the old pty is fully gone, so its exit cleanup (which
      // drops the id from the live map) can't clobber the revived session.
      const off = live.onExit(() => {
        off();
        try {
          resolve(this.resume(next, cols, rows, seed));
        } catch (err) {
          reject(err instanceof Error ? err : new Error(String(err)));
        }
      });
      live.kill();
    });
  }

  private track(session: Session): Session {
    this.sessions.set(session.id, session);
    session.onExit(() => {
      // Keep the session object around briefly so late listeners get the exit,
      // but drop it from the live map so it isn't treated as attachable.
      this.sessions.delete(session.id);
    });
    for (const l of this.createListeners) l(session);
    return session;
  }

  get(id: string): Session | undefined {
    return this.sessions.get(id);
  }

  /** Every currently live session. */
  all(): Session[] {
    return [...this.sessions.values()];
  }

  /**
   * Notify when any session is created or resumed (live again). Lets a WS
   * connection watch activity for sessions that appear after it connected.
   */
  onCreate(listener: CreateListener): () => void {
    this.createListeners.add(listener);
    return () => this.createListeners.delete(listener);
  }

  killAll(): void {
    for (const s of this.sessions.values()) s.kill();
  }
}

export const registry = new SessionRegistry();
