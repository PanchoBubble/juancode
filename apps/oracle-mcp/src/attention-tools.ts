import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { attention } from "./native-events.ts";
import { actionableAttention } from "./attention.ts";
import { fail, ok } from "./tool-result.ts";

export function registerAttentionTools(server: McpServer): void {
  server.registerTool(
    "oracle_attention",
    {
      title: "Session attention inbox",
      description:
        "Read the daemon's shared attention inbox, oldest first. Waiting reasons are unknown unless explicitly reported. Open the returned sessionId to inspect and answer; never guess approval keys.",
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    async () =>
      attention.items === null
        ? fail("Attention inbox unavailable")
        : ok(JSON.stringify(actionableAttention(attention.items))),
  );
  server.registerTool(
    "oracle_attention_acknowledge",
    {
      title: "Mark attention item read",
      description:
        "At the user's request, mark one shared inbox item read by stable ID. This does not answer questions, approve tools, or send any input to a CLI. Waiting items remain actionable until the agent resumes.",
      inputSchema: { id: z.string().min(1) },
    },
    async ({ id }) => {
      const result = await attention.acknowledge(id);
      return result.ok ? ok("Marked read") : fail(result.error ?? "Acknowledgement failed");
    },
  );
}
