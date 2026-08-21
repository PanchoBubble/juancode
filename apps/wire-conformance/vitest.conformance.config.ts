import { defineConfig } from "vitest/config";

// The live run: drives a real core over the socket and asserts the golden
// transcripts. Boots the Swift core itself unless JUANCODE_CONFORMANCE_URL points
// at one already running (that is how the Rust core gets measured).
export default defineConfig({
  test: {
    include: ["src/conformance.test.ts"],
    // One core, one socket: scenarios share the process and must not interleave.
    fileParallelism: false,
    sequence: { concurrent: false },
    testTimeout: 120_000,
    // Booting the core can include a cold `swift build`, and a sibling agent's
    // build holds the same package lock.
    hookTimeout: 25 * 60_000,
    // Building the Swift core from cold can take a few minutes, and a sibling
    // agent's `swift build` holds the same lock.
    teardownTimeout: 30_000,
  },
});
