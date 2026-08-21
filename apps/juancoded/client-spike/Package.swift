// swift-tools-version: 6.0
import PackageDescription

// A throwaway Swift client for the Rust core (juancode-52e8.3), deliberately its
// own package: the spike must not be able to disturb `apps/native`, which is the
// shipping app. The real client seam is juancode-52e8.1 (CoreClient) — this only
// has to prove the Swift UI can render a session the Rust core owns.
let package = Package(
    name: "JuancodedClientSpike",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.15.0"),
    ],
    targets: [
        .executableTarget(
            name: "JuancodedClientSpike",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            // Same call as the earlier native spike: stay in Swift 5 mode rather
            // than fight strict concurrency in throwaway code.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
