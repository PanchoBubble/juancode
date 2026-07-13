// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Juancode",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JuancodeCore", targets: ["JuancodeCore"]),
        .library(name: "JuancodePersistence", targets: ["JuancodePersistence"]),
        .library(name: "JuancodeServices", targets: ["JuancodeServices"]),
        .library(name: "JuancodeServer", targets: ["JuancodeServer"]),
        .executable(name: "juancode-smoke", targets: ["Smoke"]),
        // Headless server runner — boots the embedded WS+HTTP server without the
        // GUI, so apps/web can drive the native backend (u34.3 verification).
        .executable(name: "juancode-serve", targets: ["Serve"]),
        // The native SwiftUI app (juancode-u34.4): the local shell AND the host
        // of the embedded server. Run with `swift run juancode`.
        .executable(name: "juancode", targets: ["JuancodeApp"]),
    ],
    dependencies: [
        // SQLite persistence (juancode-u34.5). Mirrors db.ts (better-sqlite3).
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Embedded HTTP + WebSocket server (juancode-u34.3). Mirrors express + ws.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        // Native terminal emulator view for the SwiftUI shell (juancode-u34.4).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        // SPIKE: GhosttyKit (libghostty) — evaluating as a GPU-rendered replacement
        // for SwiftTerm (cleaner resize, fewer render glitches). Host-driven via
        // InMemoryTerminalSession so we keep owning the pty/byte stream.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.2.0"),
        // GitHub-flavored markdown rendering for PR-panel comment bodies
        // (juancode-lqw). Handles headings, task lists, code fences, links; HTML
        // blocks (<details> etc.) render as their inner text.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
    ],
    targets: [
        // The native core that replaces node-pty + the server's session layer
        // (juancode-u34.2). The embedded server and the GRDB store are *consumers*
        // of this core. SwiftTerm is the one exception: the headless VT engine
        // (juancode-a2h — parse once in the core, views are projections) runs a real
        // SwiftTerm `Terminal` with no view, so the core links SwiftTerm directly.
        .target(
            name: "JuancodeCore",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        // SQLite persistence (juancode-u34.5): GRDB-backed PersistentStore mirroring
        // db.ts — sessions (metadata + scrollback), diff comments, cached reviews,
        // and an FTS5 search index. The only target that depends on GRDB.
        .target(
            name: "JuancodePersistence",
            dependencies: ["JuancodeCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Auxiliary services (juancode-u34.6): 1:1 Swift `Process` ports of the
        // server's shell-out+parse modules (git, gh, beads, status, review, commit,
        // session title/usage, recovery) plus the ephemeral editor/terminal ptys.
        // Foundation + JuancodeCore only — no server/UI deps.
        .target(
            name: "JuancodeServices",
            dependencies: ["JuancodeCore"]
        ),
        // Embedded WS+HTTP server (juancode-u34.3): Hummingbird app serving the
        // protocol.ts wire format over /ws (mirrors ws.ts) + the REST endpoints
        // (mirrors index.ts). Remote browser/phone clients subscribe to registry
        // sessions here; the local SwiftUI view is an in-process subscriber.
        .target(
            name: "JuancodeServer",
            dependencies: [
                "JuancodeCore", "JuancodeServices", "JuancodePersistence",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        // Headless dev smoke: spawns the REAL claude/codex through the core to
        // prove the whole stack (registry → session → forkpty) end-to-end.
        .executableTarget(
            name: "Smoke",
            dependencies: ["JuancodeCore"]
        ),
        .executableTarget(
            name: "Serve",
            dependencies: ["JuancodeServer"]
        ),
        // SwiftUI shell (juancode-u34.4): NavigationSplitView sidebar + SwiftTerm
        // session view (an in-process subscriber to the registry — no WS hop) +
        // new-session flow. Embeds JuancodeServer so remote clients still work.
        .executableTarget(
            name: "JuancodeApp",
            dependencies: [
                "JuancodeCore", "JuancodeServices", "JuancodePersistence", "JuancodeServer",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                // SPIKE: GhosttyKit (libghostty) GPU-rendered terminal, the default
                // live surface; JUANCODE_SWIFTTERM=1 falls back to SwiftTerm for
                // A/B comparison. See GhosttyLive.swift.
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ]
        ),
        .testTarget(
            name: "JuancodeCoreTests",
            dependencies: ["JuancodeCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(
            name: "JuancodePersistenceTests",
            dependencies: ["JuancodePersistence"]
        ),
        .testTarget(
            name: "JuancodeServicesTests",
            dependencies: ["JuancodeServices"]
        ),
        .testTarget(
            name: "JuancodeServerTests",
            dependencies: [
                "JuancodeServer", "JuancodePersistence",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
    ]
)
