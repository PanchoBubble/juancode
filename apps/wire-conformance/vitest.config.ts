import { defineConfig } from "vitest/config";

// The default run: everything that needs no live core. Spec integrity, the
// matcher engine, capability negotiation, and the drift guard that compares the
// spec against WireProtocol.swift. Fast enough for `pnpm test` at the repo root.
export default defineConfig({
  test: {
    include: ["src/**/*.test.ts"],
    exclude: ["src/conformance.test.ts"],
  },
});
