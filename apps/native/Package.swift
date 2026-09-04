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
        .library(name: "JuancodeClient", targets: ["JuancodeClient"]),
        .executable(name: "juancode-smoke", targets: ["Smoke"]),
        // Headless server runner — answers port 4280 without the GUI. Boots the
        // embedded WS+HTTP server on the swift core (u34.3 verification), or with
        // `--core rust` relays to the `juancoded` daemon so the oracle sidecar is
        // not blind while the desktop app is closed (juancode-eko6).
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
        //
        // 1.14 or newer is required, not just preferred: the GPU path in 1.13 placed
        // glyphs on CoreText's shaped advances instead of the terminal's cell grid, so
        // rows drifted left of the cursor as you typed (~3 cells by column 80).
        // Upstream 13732b7 fixed it, first released in 1.14.0.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.15.0"),
        // GhosttyKit (libghostty): GPU-rendered alternative live surface, selectable
        // in Settings → Terminal. Host-driven via InMemoryTerminalSession so we keep
        // owning the pty/byte stream.
        //
        // 1.3.0 or newer is required: 1.2.x wrote to the surface synchronously on the
        // calling thread, which deadlocked the main thread on a Zig futex when several
        // panes attached at once (juancode-d89, filed as libghostty-spm#28). Their
        // PR #29 moved those writes onto a per-session serial queue.
        //
        // VENDORED, not fetched (juancode-o9h2): `vendor/libghostty-spm` is upstream
        // 1.3.2 verbatim plus one fix. PR #29 moved the wedging write off the main
        // thread but left `InMemoryTerminalSurfaceAccess` draining it with an
        // unbounded `NSCondition.wait()` — and that drain runs on the MAIN thread from
        // a view's deinit, so a write wedged inside libghostty froze the whole app
        // permanently (twice: 3 and 6 Aug 2026). The patch bounds the drain and leaks
        // the surface instead of freeing it under a live C call. Every patched site is
        // marked `juancode patch`. Drop the vendoring and go back to the remote
        // package once this is fixed upstream.
        .package(path: "vendor/libghostty-spm"),
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
        // The seam the SwiftUI app talks to a core through: `CoreClient` (modelled
        // on the wire message set) plus `SwiftCoreClient`, which fronts the
        // in-process registry/store/services. Its own target so the boundary is
        // compiler-enforced, so `JuancodeApp` cannot reach past it into `AppState`.
        .target(
            name: "JuancodeClient",
            dependencies: ["JuancodeCore", "JuancodeServices", "JuancodePersistence", "JuancodeServer"]
        ),
        // Headless dev smoke: spawns the REAL claude/codex through the core to
        // prove the whole stack (registry → session → forkpty) end-to-end.
        .executableTarget(
            name: "Smoke",
            dependencies: ["JuancodeCore"]
        ),
        // `JuancodeClient` as well as the server, for the rust serve mode
        // (juancode-eko6): `--core rust` fronts the `juancoded` daemon with the same
        // `CoreProxyServer` relay the shell boots, and that needs `RustCoreClient`.
        .executableTarget(
            name: "Serve",
            dependencies: ["JuancodeServer", "JuancodeClient"]
        ),
        // SwiftUI shell (juancode-u34.4): NavigationSplitView sidebar + SwiftTerm
        // session view (an in-process subscriber to the registry — no WS hop) +
        // new-session flow. Reaches the core only through JuancodeClient, which also
        // boots the embedded server so remote clients still work.
        .executableTarget(
            name: "JuancodeApp",
            dependencies: [
                "JuancodeCore", "JuancodeServices", "JuancodePersistence", "JuancodeClient",
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
            name: "JuancodeClientTests",
            dependencies: [
                "JuancodeClient", "JuancodePersistence",
                // A stand-in daemon over a real socket, so the frames the client
                // sends are asserted as frames rather than as mocked method calls.
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
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
