import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Port of `apps/server/src/status.test.ts`. The TS file only exercises the two
/// pure parsers; we mirror those exactly, then add a `getAllStatus` test that
/// injects fake `claude`/`codex` binaries via a custom `BinaryResolver` — the
/// Swift equivalent of swapping the CLIs through the env-var overrides.

final class ParseClaudeListTests: XCTestCase {
    func testParsesNamesWithColonsTransportStatusAndWarning() {
        let out = [
            "⚠ claude.ai connectors are disabled because ANTHROPIC_API_KEY is set",
            "Checking MCP server health…",
            "",
            "plugin:linear:linear: https://mcp.linear.app/mcp (HTTP) - ! Needs authentication",
            "pencil: /Applications/Pencil.app/out/mcp-server --app desktop - ✔ Connected",
        ].joined(separator: "\n")

        let (servers, warning) = parseClaudeList(out)

        XCTAssertEqual(warning, "claude.ai connectors are disabled because ANTHROPIC_API_KEY is set")
        XCTAssertEqual(servers.count, 2)

        // Name retains its internal colons; split happens on the first ": ".
        XCTAssertEqual(servers[0].name, "plugin:linear:linear")
        XCTAssertEqual(servers[0].detail, "https://mcp.linear.app/mcp (HTTP)")
        XCTAssertEqual(servers[0].transport, "http")
        XCTAssertEqual(servers[0].health, .needsAuth)

        // stdio command with its own flags survives (no " - " inside it).
        XCTAssertEqual(servers[1].name, "pencil")
        XCTAssertEqual(servers[1].detail, "/Applications/Pencil.app/out/mcp-server --app desktop")
        XCTAssertEqual(servers[1].health, .connected)
    }

    func testTreatsNoServersMessageAsEmptyList() {
        let (servers, warning) = parseClaudeList("No MCP servers configured. Use `claude mcp add`.")
        XCTAssertEqual(servers, [])
        XCTAssertNil(warning)
    }
}

final class ParseCodexListTests: XCTestCase {
    func testMapsStdioHttpTransportsAuthAndEnabledState() throws {
        let json = """
        [
          {"name":"cloudwatch","enabled":true,"disabled_reason":null,"transport":{"type":"stdio","command":"uvx","args":["awslabs.cloudwatch-mcp-server@latest"]},"auth_status":"unsupported"},
          {"name":"linear","enabled":true,"disabled_reason":null,"transport":{"type":"streamable_http","url":"https://mcp.linear.app/mcp"},"auth_status":"o_auth"},
          {"name":"old","enabled":false,"disabled_reason":"removed from config","transport":{"type":"stdio","command":"foo"},"auth_status":null}
        ]
        """

        let servers = parseCodexList(json)
        XCTAssertEqual(servers.count, 3)

        XCTAssertEqual(servers[0].name, "cloudwatch")
        XCTAssertEqual(servers[0].detail, "uvx awslabs.cloudwatch-mcp-server@latest")
        XCTAssertEqual(servers[0].transport, "stdio")
        XCTAssertEqual(servers[0].health, .enabled)
        XCTAssertNil(servers[0].auth) // "unsupported" is normalized away

        XCTAssertEqual(servers[1].detail, "https://mcp.linear.app/mcp")
        XCTAssertEqual(servers[1].transport, "http")
        XCTAssertEqual(servers[1].auth, "oauth")

        XCTAssertEqual(servers[2].health, .disabled)
        XCTAssertEqual(servers[2].statusLabel, "removed from config")
    }

    func testReturnsEmptyListForNonJsonInput() {
        XCTAssertEqual(parseCodexList("not json"), [])
    }
}

/// `opencode mcp list` has no --json: it prints a coloured tree, one bullet line per
/// server plus an indented detail line. This is its real output, escapes included.
final class ParseOpencodeListTests: XCTestCase {
    func testParsesBulletLinesWithTheirDetailAndHealth() {
        let out = [
            "\u{1B}[0m",
            "\u{1B}[36m┌\u{1B}[0m  MCP Servers",
            "│",
            "●  ✓ linear \u{1B}[90mconnected",
            "│      \u{1B}[90mhttps://mcp.linear.app/mcp",
            "│",
            "●  ✗ pencil \u{1B}[90mfailed to connect",
            "│      \u{1B}[90m/Applications/Pen.app/out/mcp-server --app desktop",
            "│",
            "└  2 server(s)",
        ].joined(separator: "\n")

        let servers = parseOpencodeList(out)
        XCTAssertEqual(servers.count, 2)

        XCTAssertEqual(servers[0].name, "linear")
        XCTAssertEqual(servers[0].detail, "https://mcp.linear.app/mcp")
        XCTAssertEqual(servers[0].transport, "http")
        XCTAssertEqual(servers[0].health, .connected)
        XCTAssertEqual(servers[0].statusLabel, "connected")

        XCTAssertEqual(servers[1].name, "pencil")
        XCTAssertEqual(servers[1].detail, "/Applications/Pen.app/out/mcp-server --app desktop")
        XCTAssertEqual(servers[1].transport, "stdio")
        XCTAssertEqual(servers[1].health, .failed)
    }

    func testTheSummaryLineIsNotMistakenForADetail() {
        let servers = parseOpencodeList("●  ✓ linear connected\n└  1 server(s)")
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].detail, "")
    }

    func testAnEmptyOrUnexpectedOutputYieldsNoServers() {
        XCTAssertEqual(parseOpencodeList(""), [])
        XCTAssertEqual(parseOpencodeList("No MCP servers configured"), [])
    }
}

/// Drives `getAllStatus` end-to-end against fake `claude`/`codex` scripts. The
/// resolver returns absolute script paths (≈ the `JUANCODE_*_BIN` overrides the
/// TS honours), so no real CLI is needed.
final class GetAllStatusTests: XCTestCase {
    private var dir: String = ""

    override func setUpWithError() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        dir = path
    }

    override func tearDownWithError() throws {
        if !dir.isEmpty { try? FileManager.default.removeItem(atPath: dir) }
    }

    func testAggregatesBothProvidersInOrder() async throws {
        // Fake claude: `--version` prints a banner; `mcp list` prints one server
        // on stdout and a warning on stderr (claude's real split).
        let claude = try writeScript("fake-claude", """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "1.2.3 (Claude Code)"; exit 0; fi
        if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
          echo "⚠ connectors disabled" 1>&2
          echo "pencil: /opt/pencil --app desktop - ✔ Connected"
          exit 0
        fi
        exit 0
        """)
        // Fake codex: `--version` then `mcp list --json` emits a config array.
        let codex = try writeScript("fake-codex", """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "codex 9.9.9"; exit 0; fi
        if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
        cat <<'JSON'
        [{"name":"linear","enabled":true,"disabled_reason":null,"transport":{"type":"streamable_http","url":"https://mcp.linear.app/mcp"},"auth_status":"o_auth"}]
        JSON
          exit 0
        fi
        exit 0
        """)

        let resolver = FakeResolver(paths: [.claude: claude, .codex: codex])
        let all = await getAllStatus(resolver: resolver)

        // Order preserved (ProviderId.allCases: claude, codex, opencode). opencode has
        // no fake script here, so it reports unavailable — the point is the ordering.
        XCTAssertEqual(all.map { $0.id }, [.claude, .codex, .opencode])

        let c = all[0]
        XCTAssertEqual(c.id, .claude)
        XCTAssertTrue(c.available)
        XCTAssertEqual(c.version, "1.2.3 (Claude Code)")
        XCTAssertEqual(c.warning, "connectors disabled")
        XCTAssertNil(c.error)
        XCTAssertEqual(c.mcpServers.count, 1)
        XCTAssertEqual(c.mcpServers[0].name, "pencil")
        XCTAssertEqual(c.mcpServers[0].health, .connected)

        let x = all[1]
        XCTAssertEqual(x.id, .codex)
        XCTAssertTrue(x.available)
        XCTAssertEqual(x.version, "codex 9.9.9")
        XCTAssertEqual(x.mcpServers.count, 1)
        XCTAssertEqual(x.mcpServers[0].transport, "http")
        XCTAssertEqual(x.mcpServers[0].auth, "oauth")
    }

    func testUnavailableProviderReportsError() async throws {
        let resolver = FakeResolver(paths: [
            .claude: "/no/such/claude-xyz",
            .codex: "/no/such/codex-xyz",
        ])
        let all = await getAllStatus(resolver: resolver)
        for s in all {
            XCTAssertFalse(s.available)
            XCTAssertNil(s.version)
            XCTAssertNotNil(s.error)
            XCTAssertTrue(s.mcpServers.isEmpty)
        }
    }

    private func writeScript(_ name: String, _ body: String) throws -> String {
        let path = (dir as NSString).appendingPathComponent(name)
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
}

/// A `BinaryResolver` that hands back canned absolute paths per provider.
private struct FakeResolver: BinaryResolver {
    let paths: [ProviderId: String]
    func command(for provider: ProviderId) -> String { paths[provider] ?? "" }
}
