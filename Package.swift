// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nymbra",
    platforms: [.macOS(.v11)],
    targets: [
        // forkpty() lives in <util.h>, which Swift cannot import directly.
        .target(name: "CPTY"),

        // Everything that is not UI: PTY, screen buffer, and (soon) VT parsing.
        .target(name: "NymbraCore", dependencies: ["CPTY"]),

        // The app itself.
        .executableTarget(name: "Nymbra", dependencies: ["NymbraCore"]),

        // Zero-dependency test harness. Not a SwiftPM testTarget: XCTest and
        // swift-testing are unavailable with Command Line Tools alone.
        .executableTarget(name: "NymbraCheck", dependencies: ["NymbraCore"]),
    ],
    swiftLanguageModes: [.v5]
)
