/**
 * Per-session pty grid arbitration (juancode-1th.1).
 *
 * A session's pty is a single shared grid, but several clients may view it at
 * once (native app view + web + phone PWA), each at a different size. Without
 * arbitration every `attach`/`resize` wrote the grid last-write-wins, so with two
 * different-sized viewers the CLI TUI flapped back and forth between their sizes.
 *
 * This gives each session a single *controlling* owner: the first client to set
 * the grid claims it and holds it until it disconnects ({@link release}), at which
 * point the next client's request takes over. The in-process local native view
 * ({@link LOCAL_GRID_OWNER}) preempts a remote owner, so the primary on-screen
 * surface always drives the grid. A non-owner's request is denied — the caller
 * renders the pty's actual grid as-is instead of fighting for it.
 *
 * Pure and dependency-free so it can be unit-tested without a real pty; mirrored
 * in Swift as `apps/native/Sources/JuancodeCore/GridArbiter.swift`.
 */

/**
 * Reserved owner id for the in-process local view (the native app's own terminal).
 * It preempts a remote owner so dragging the native window always wins the grid,
 * per the "native app is the primary surface" policy. The Node server has no local
 * view and never uses it, but the id is shared so the policy reads identically in
 * both twins.
 */
export const LOCAL_GRID_OWNER = "__local__";

export class GridArbiter {
  private owner: string | null = null;

  /**
   * Whether `owner` may drive the grid right now. Claims the grid when it's free
   * or already held by `owner`, and lets the local view preempt a remote owner.
   * Returns false when a different client owns the grid (the request is denied).
   */
  request(owner: string): boolean {
    if (this.owner === null || this.owner === owner || owner === LOCAL_GRID_OWNER) {
      this.owner = owner;
      return true;
    }
    return false;
  }

  /**
   * Release ownership held by `owner` (its client disconnected / its view was torn
   * down) so the next client's request can claim the grid. No-op if `owner` isn't
   * the current owner. Returns whether ownership was actually freed, so a caller
   * can notify observers on the real transition only.
   */
  release(owner: string): boolean {
    if (this.owner !== owner) return false;
    this.owner = null;
    return true;
  }

  /** The current controlling owner, or null when the grid is unclaimed. */
  get current(): string | null {
    return this.owner;
  }
}
