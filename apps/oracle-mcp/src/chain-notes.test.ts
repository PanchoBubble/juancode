import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { fakeChainDeps } from "./chains-fake.ts";
import {
  chainNotesFor,
  chainNotesJson,
  chainNotesPath,
  postChainNote,
  readChainNotes,
} from "./chain-notes.ts";
import type { Chain } from "./native-events.ts";

const chain: Chain = {
  id: "c0ffee00-1111-2222-3333-444455556666",
  slug: "c0ffee00-1111-2222-3333-444455556666",
  name: "Board access",
  state: "active",
  createdAt: 1,
  closedAt: null,
  members: [{ kind: "session", ref: "sess-worker", addedAt: 1 }],
};
const sessions = [
  {
    id: "sess-worker",
    provider: "claude",
    cwd: "/repo",
    title: "worker",
    status: "running",
    archived: false,
    updatedAt: 1,
    cliSessionId: "cli-123",
  },
];

let dir: string;
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "chain-notes-"));
});
afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

describe("chain notes", () => {
  it("finds the chain from the CLI session id and stamps the writer", async () => {
    const deps = fakeChainDeps({ book: [chain], sessions });
    const { note } = await postChainNote(
      deps,
      { fromSessionId: "cli-123", text: "tests green" },
      dir,
    );
    expect(note).toMatchObject({ author: "sess-worker", authorName: "worker", kind: "note" });
    await postChainNote(
      deps,
      { chain: "board access", text: "ship by friday", kind: "summary", asHuman: true },
      dir,
    );
    const notes = await readChainNotes(chain.id!, dir);
    expect(notes.map((n) => [n.author, n.kind])).toEqual([
      ["sess-worker", "note"],
      ["you", "summary"],
    ]);
    const text = await chainNotesFor(deps, { chain: chain.id }, undefined, dir);
    expect(text).toContain("ship by friday");
    expect(text).toContain("tests green");
    const json = await chainNotesJson(deps, { chain: chain.id }, undefined, dir);
    expect(json).toMatchObject({
      chain: chain.id,
      name: "Board access",
      summary: { text: "ship by friday", kind: "summary" },
    });
    expect(json.notes.map((n) => n.text)).toEqual(["tests green"]);
  });

  it("refuses a session outside any chain and an id that leaves the directory", async () => {
    const deps = fakeChainDeps({ book: [{ ...chain, members: [] }], sessions });
    await expect(postChainNote(deps, { fromSessionId: "cli-123", text: "x" }, dir)).rejects.toThrow(
      /not in a chain/,
    );
    expect(() => chainNotesPath("../etc", dir)).toThrow();
  });

  it("skips a torn line instead of failing the read", async () => {
    const deps = fakeChainDeps({ book: [chain], sessions });
    await postChainNote(deps, { chain: chain.id, text: "one" }, dir);
    const { appendFile } = await import("node:fs/promises");
    await appendFile(chainNotesPath(chain.id!, dir), '{"broken"\n');
    await postChainNote(deps, { chain: chain.id, text: "two" }, dir);
    expect((await readChainNotes(chain.id!, dir)).map((n) => n.text)).toEqual(["one", "two"]);
    expect(await readFile(chainNotesPath(chain.id!, dir), "utf8")).toContain("broken");
  });
});
