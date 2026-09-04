import { createServer } from "node:net";
import { describe, expect, it } from "vitest";
import { conformancePort, DEFAULT_PORT, freePort } from "./core.ts";

describe("conformancePort", () => {
  it("defaults when the variable is unset or empty", () => {
    expect(conformancePort(undefined)).toBe(DEFAULT_PORT);
    expect(conformancePort("")).toBe(DEFAULT_PORT);
    expect(conformancePort("  ")).toBe(DEFAULT_PORT);
  });

  it("keeps a port a caller named", () => {
    expect(conformancePort("4300")).toBe(4300);
  });

  it("reads 0 as a request for an ephemeral port rather than as a default", () => {
    expect(conformancePort("0")).toBe(0);
  });

  it("refuses something that is not a port instead of silently defaulting", () => {
    expect(() => conformancePort("nope")).toThrow(/not a port/);
    expect(() => conformancePort("70000")).toThrow(/not a port/);
    expect(() => conformancePort("-1")).toThrow(/not a port/);
    expect(() => conformancePort("4300.5")).toThrow(/not a port/);
  });
});

describe("freePort", () => {
  it("returns a port that is actually free to bind", async () => {
    const port = await freePort();
    expect(port).toBeGreaterThan(1024);
    expect(port).not.toBe(4280);
    expect(port).not.toBe(4281);
    // The point of the allocation is that the caller can now bind it; if the
    // probe socket had been left open this would fail with EADDRINUSE.
    await new Promise<void>((resolve, reject) => {
      const srv = createServer();
      srv.on("error", reject);
      srv.listen({ host: "127.0.0.1", port }, () => srv.close(() => resolve()));
    });
  });

  it("does not hand out a port something is already listening on", async () => {
    const taken = await freePort();
    const holder = createServer();
    await new Promise<void>((resolve, reject) => {
      holder.on("error", reject);
      holder.listen({ host: "127.0.0.1", port: taken }, () => resolve());
    });
    try {
      for (let i = 0; i < 5; i++) expect(await freePort()).not.toBe(taken);
    } finally {
      await new Promise<void>((resolve) => holder.close(() => resolve()));
    }
  });
});
