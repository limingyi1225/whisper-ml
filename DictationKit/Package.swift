// swift-tools-version: 6.2
import PackageDescription

// The speech half of Whisper, split out so Wink can use it without a second
// copy. Whisper remains the primary consumer; this is a code-sharing boundary,
// not a general-purpose library.
//
// The build settings below are not preferences — they mirror the Whisper app
// target exactly, because these files were written under them and their
// meaning changes without them. Verified against the real compiler invocation:
//
//     xcodebuild … clean build 2>&1 | grep -oE "-enable-upcoming-feature [A-Za-z]+"
//
// `defaultIsolation(MainActor.self)` corresponds to the target's
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; the upcoming features are what
// `SWIFT_APPROACHABLE_CONCURRENCY = YES` expands to on this toolchain, plus
// `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`. If the app target's
// settings change, re-run that command and change these to match.
//
// `NonisolatedNonsendingByDefault` in particular decides which executor a
// nonisolated async function runs on — dropping it would silently move work
// off the main actor.
let package = Package(
    name: "DictationKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DictationKit", targets: ["DictationKit"])
    ],
    targets: [
        .target(
            name: "DictationKit",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("DisableOutwardActorInference"),
                .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "DictationKitTests",
            dependencies: ["DictationKit"]
        )
    ]
)
