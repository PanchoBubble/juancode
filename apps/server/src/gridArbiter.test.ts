import { describe, expect, it } from "vitest";
import { GridArbiter, LOCAL_GRID_OWNER } from "./gridArbiter.ts";

describe("GridArbiter", () => {
  it("lets the first client claim the grid", () => {
    const g = new GridArbiter();
    expect(g.request("a")).toBe(true);
    expect(g.current).toBe("a");
  });

  it("denies a second client while the first still owns the grid", () => {
    const g = new GridArbiter();
    g.request("a");
    expect(g.request("b")).toBe(false);
    // The owner is unchanged — a denied request must not steal ownership, or two
    // viewers' resizes would flap the grid last-write-wins.
    expect(g.current).toBe("a");
  });

  it("keeps letting the current owner drive the grid", () => {
    const g = new GridArbiter();
    g.request("a");
    expect(g.request("a")).toBe(true);
    expect(g.request("a")).toBe(true);
  });

  it("lets the next client claim after the owner releases (disconnect)", () => {
    const g = new GridArbiter();
    g.request("a");
    g.release("a");
    expect(g.current).toBeNull();
    expect(g.request("b")).toBe(true);
    expect(g.current).toBe("b");
  });

  it("ignores a release from a non-owner", () => {
    const g = new GridArbiter();
    g.request("a");
    g.release("b"); // b never owned it
    expect(g.current).toBe("a");
    // b still can't take over — a is very much the owner.
    expect(g.request("b")).toBe(false);
  });

  it("lets the local view preempt a remote owner (native is the primary surface)", () => {
    const g = new GridArbiter();
    g.request("remote");
    expect(g.request(LOCAL_GRID_OWNER)).toBe(true);
    expect(g.current).toBe(LOCAL_GRID_OWNER);
    // While local holds it, the remote is denied.
    expect(g.request("remote")).toBe(false);
  });

  it("frees the grid for a remote client once the local view releases", () => {
    const g = new GridArbiter();
    g.request(LOCAL_GRID_OWNER);
    expect(g.request("remote")).toBe(false);
    g.release(LOCAL_GRID_OWNER);
    expect(g.request("remote")).toBe(true);
  });

  it("reports whether a release actually freed ownership", () => {
    const g = new GridArbiter();
    g.request("a");
    // A non-owner's release must not read as a transition, or observers would
    // see spurious "grid went unclaimed" events (mirrors the Swift twin).
    expect(g.release("b")).toBe(false);
    expect(g.release("a")).toBe(true);
    expect(g.release("a")).toBe(false); // already free
  });
});
