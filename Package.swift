// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nymbra",
    platforms: [.macOS(.v11)],
    targets: [
        // forkpty() lives in <util.h>, which Swift cannot import directly.
        .target(name: "CPTY"),

        // The one thing posix_spawn cannot do: hand a child a controlling
        // terminal (ADR-0008). Exec'd before every shell, so it stays small and
        // imports nothing.
        .executableTarget(name: "NymbraSpawn", path: "Sources/NymbraSpawn"),

        // Everything that is not UI: PTY, screen model, VT parsing.
        .target(name: "NymbraCore", dependencies: ["CPTY"]),

        // Keyboard-to-bytes mapping. UI-free on purpose: "arrows and function
        // keys work" is a property of this table, not of a window, so it must be
        // assertable headlessly.
        .target(name: "NymbraInput"),

        // The app itself.
        .executableTarget(name: "Nymbra", dependencies: ["NymbraCore", "NymbraInput"]),

        // Zero-dependency test harness. Not a SwiftPM testTarget: XCTest and
        // swift-testing are unavailable with Command Line Tools alone.
        .executableTarget(name: "NymbraCheck", dependencies: ["NymbraCore", "NymbraInput"]),
    ],
    swiftLanguageModes: [.v5]
)
