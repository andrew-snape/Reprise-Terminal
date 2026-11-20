// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Reprise-Terminal",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "reprise", targets: ["reprise"])
    ],
    targets: [
        // One module: the CLI files and the vendored RivuletCore together, since
        // RivuletCore's types are internal (it was written for a single app target).
        .executableTarget(
            name: "reprise",
            path: "Sources/reprise",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
