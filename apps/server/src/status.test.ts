import { describe, expect, it } from "vitest";
import { parseClaudeList, parseCodexList } from "./status.ts";

describe("parseClaudeList", () => {
  it("parses names with colons, transport, and status; captures the warning banner", () => {
    const out = [
      "⚠ claude.ai connectors are disabled because ANTHROPIC_API_KEY is set",
      "Checking MCP server health…",
      "",
      "plugin:linear:linear: https://mcp.linear.app/mcp (HTTP) - ! Needs authentication",
      "pencil: /Applications/Pencil.app/out/mcp-server --app desktop - ✔ Connected",
    ].join("\n");

    const { servers, warning } = parseClaudeList(out);

    expect(warning).toBe("claude.ai connectors are disabled because ANTHROPIC_API_KEY is set");
    expect(servers).toHaveLength(2);

    // Name retains its internal colons; split happens on the first ": ".
    expect(servers[0]).toMatchObject({
      name: "plugin:linear:linear",
      detail: "https://mcp.linear.app/mcp (HTTP)",
      transport: "http",
      health: "needs-auth",
    });
    // stdio command with its own flags survives (no " - " inside it).
    expect(servers[1]).toMatchObject({
      name: "pencil",
      detail: "/Applications/Pencil.app/out/mcp-server --app desktop",
      health: "connected",
    });
  });

  it("treats the no-servers message as an empty list", () => {
    const { servers, warning } = parseClaudeList("No MCP servers configured. Use `claude mcp add`.");
    expect(servers).toEqual([]);
    expect(warning).toBeNull();
  });
});

describe("parseCodexList", () => {
  it("maps stdio + http transports, auth, and enabled state", () => {
    const json = JSON.stringify([
      {
        name: "cloudwatch",
        enabled: true,
        disabled_reason: null,
        transport: { type: "stdio", command: "uvx", args: ["awslabs.cloudwatch-mcp-server@latest"] },
        auth_status: "unsupported",
      },
      {
        name: "linear",
        enabled: true,
        disabled_reason: null,
        transport: { type: "streamable_http", url: "https://mcp.linear.app/mcp" },
        auth_status: "o_auth",
      },
      {
        name: "old",
        enabled: false,
        disabled_reason: "removed from config",
        transport: { type: "stdio", command: "foo" },
        auth_status: null,
      },
    ]);

    const servers = parseCodexList(json);
    expect(servers).toHaveLength(3);

    expect(servers[0]).toMatchObject({
      name: "cloudwatch",
      detail: "uvx awslabs.cloudwatch-mcp-server@latest",
      transport: "stdio",
      health: "enabled",
      auth: null, // "unsupported" is normalized away
    });
    expect(servers[1]).toMatchObject({
      detail: "https://mcp.linear.app/mcp",
      transport: "http",
      auth: "oauth",
    });
    expect(servers[2]).toMatchObject({ health: "disabled", statusLabel: "removed from config" });
  });

  it("returns an empty list for non-JSON input", () => {
    expect(parseCodexList("not json")).toEqual([]);
  });
});
