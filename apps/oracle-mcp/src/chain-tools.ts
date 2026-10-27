// The chain_* MCP tools (juancode-dbo.10): the Oracle lists, reads, creates, tags into,
// untags from and closes chains — named cross-project groups of sessions, tracked PRs,
// beads issues and Linear tickets. The daemon keeps the book; every body here is a
// chains.ts call, the same one Telegram's /chains makes.

import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  chainAdd,
  chainClose,
  chainCreate,
  chainCreateNamed,
  chainListText,
  chainRemove,
  chainShowText,
  defaultChainDeps,
  readBook,
  type ChainDeps,
} from "./chains.ts";
import { ok, tool, type ToolResult } from "./tool-result.ts";

const slug = z.string().min(1).describe("The chain UUID (or a legacy slug)");

const member = {
  kind: z
    .enum(["session", "tracked_pr", "beads", "linear"])
    .describe(
      "What the item is: an agent or Oracle session, a tracked PR, a beads issue, or a Linear ticket",
    ),
  ref: z
    .string()
    .min(1)
    .describe(
      "The item's id: a session id (or unique prefix, from oracle_list_sessions), a PR's tracked key '<absolute repo path>#<number>' (or just the number with prCwd), a beads id like 'juancode-dbo.10', or a Linear identifier like 'ENG-123'",
    ),
  prCwd: z
    .string()
    .optional()
    .describe(
      "For kind tracked_pr given by number: the absolute path of the repo checkout it is tracked under",
    ),
};

/** A tool body that answers in words, with a refusal or a thrown error as `isError`. */
function answer<A>(body: (args: A) => Promise<string>): (args: A) => Promise<ToolResult> {
  return (args) => tool(async () => ok(await body(args)))();
}

/** Bind the chain tools. `deps` is resolved per call, so a test can hand in a fake. */
export function registerChainTools(
  server: McpServer,
  deps: () => ChainDeps = defaultChainDeps,
): void {
  server.registerTool(
    "chain_list",
    {
      title: "List chains",
      description:
        "List the chains — named groups that tag related sessions, PRs, beads issues and Linear tickets across projects — with a member count per kind. Active ones by default.",
      inputSchema: {
        state: z
          .enum(["active", "inactive", "all"])
          .optional()
          .describe("Which chains: active (default), inactive (closed), or all"),
      },
    },
    answer(async (args) => chainListText(await readBook(deps()), args.state ?? "active")),
  );

  server.registerTool(
    "chain_show",
    {
      title: "Show one chain",
      description:
        "Everything in one chain, grouped by kind: its sessions with project, provider and live status (working, waiting for input, idle, exited), its PRs, beads issues and Linear tickets. Use for 'what's going on in <chain>'.",
      inputSchema: { slug },
    },
    answer((args) => chainShowText(deps(), args.slug)),
  );

  server.registerTool(
    "chain_create",
    {
      title: "Create a chain",
      description:
        "Create an empty active chain with a display name and generated UUID. Use name for new chains; slug is accepted for legacy callers. Use the returned ID with chain_add.",
      inputSchema: { name: z.string().trim().min(1).max(200).optional(), slug: slug.optional() },
    },
    answer((args) => {
      if (args.name) return chainCreateNamed(deps(), args.name);
      if (args.slug) return chainCreate(deps(), args.slug);
      throw new Error("Provide a chain name.");
    }),
  );

  server.registerTool(
    "chain_add",
    {
      title: "Tag an item into a chain",
      description:
        "Put a session (your own Oracle session included), tracked PR, beads issue or Linear ticket into a chain. An item is in at most one chain, so this MOVES it out of any other chain it was in. title/url are a snapshot shown beside the item — worth giving for beads and Linear refs, which the daemon cannot look up.",
      inputSchema: {
        slug,
        ...member,
        title: z.string().optional().describe("A short human title to show for the item"),
        url: z.string().optional().describe("A link to the item"),
      },
    },
    answer(({ slug, ...item }) => chainAdd(deps(), slug, item)),
  );

  server.registerTool(
    "chain_remove",
    {
      title: "Untag an item from its chain",
      description:
        "Take a session, tracked PR, beads issue or Linear ticket out of its chain. The item itself is untouched. Pass slug to remove it only if it is still in that chain.",
      inputSchema: {
        ...member,
        slug: slug.optional().describe("Only remove it if it is in this chain"),
      },
    },
    answer((args) => chainRemove(deps(), args)),
  );

  server.registerTool(
    "chain_close",
    {
      title: "Close a chain",
      description:
        "Mark a chain inactive once its work is done. Members stay tagged and nothing is deleted; it drops out of chain_list's default view.",
      inputSchema: { slug },
    },
    answer((args) => chainClose(deps(), args.slug)),
  );
}
