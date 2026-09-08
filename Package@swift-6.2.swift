// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let package = Package(
    name: "argmax-oss-swift",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "WhisperKit",
            targets: ["WhisperKit"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ArgmaxCore",
            swiftSettings: swiftSettings()
        ),
        .target(
            name: "WhisperKit",
            dependencies: [
                "ArgmaxCore",
            ],
            swiftSettings: swiftSettings()
        ),
    ],
    swiftLanguageModes: [.v6]
)

func swiftSettings(libraryEvolution: Bool = true) -> [SwiftSetting] {
    // Opt-in to Swift 6.2's "Approachable Concurrency" upcoming features.
    // These reduce false-positive concurrency diagnostics by making the
    // compiler infer isolation in places where it's almost always what the
    // developer intended:
    //   - InferIsolatedConformances (SE-0470): a protocol conformance on a
    //     globally-isolated type (e.g. @MainActor) is itself inferred to be
    //     isolated to that same actor, instead of forcing a `nonisolated`
    //     conformance that can't touch the type's state.
    //   - NonisolatedNonsendingByDefault (SE-0461): a `nonisolated` async
    //     function runs on the caller's actor by default rather than hopping
    //     to the generic executor, avoiding spurious Sendable errors on
    //     arguments and return values that never actually cross actors.
    let approachableConcurrencySettings: [SwiftSetting] = [
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    ]

    // Equivalent to Xcode's BUILD_LIBRARY_FOR_DISTRIBUTION setting: enables
    // library evolution and module stability so these targets can be linked
    // against prebuilt binary frameworks (e.g. an .xcframework) without
    // requiring the framework to be rebuilt for every Swift compiler version.
    let dynamicSettings: [SwiftSetting] = libraryEvolution ? [
        .unsafeFlags([
            "-enable-library-evolution",
            "-Xfrontend", "-alias-module-names-in-module-interface",
        ])
    ] : []

    return approachableConcurrencySettings + dynamicSettings
}
