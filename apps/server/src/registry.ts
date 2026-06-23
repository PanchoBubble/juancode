import { Session } from "./session.ts";
import type { ProviderId } from "./protocol.ts";

/** Holds the live (in-memory) ptys for the current server lifetime. */
class SessionRegistry {
  private readonly sessions = new Map<string, Session>();

  create(provider: ProviderId, cwd: string, cols: number, rows: number): Session {
    const session = new Session(provider, cwd, cols, rows);
    this.sessions.set(session.id, session);
    session.onExit(() => {
      // Keep the session object around briefly so late listeners get the exit,
      // but drop it from the live map so it isn't treated as attachable.
      this.sessions.delete(session.id);
    });
    return session;
  }

  get(id: string): Session | undefined {
    return this.sessions.get(id);
  }

  killAll(): void {
    for (const s of this.sessions.values()) s.kill();
  }
}

export const registry = new SessionRegistry();
