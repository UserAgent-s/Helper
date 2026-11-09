// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UserAgent057Core",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "RealtimeClient", targets: ["RealtimeClient"]),
        .library(name: "Transcription", targets: ["Transcription"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "SecurityStore", targets: ["SecurityStore"]),
        .library(name: "Diagnostics", targets: ["Diagnostics"]),
        .library(name: "Summary", targets: ["Summary"]),
        .library(name: "OverlayReducer", targets: ["OverlayReducer"]),
        .library(name: "CompanionProtocol", targets: ["CompanionProtocol"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
    ],
    targets: [
        .target(
            name: "Domain",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AudioCapture",
            dependencies: ["Domain"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "RealtimeClient",
            dependencies: ["Domain"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Transcription",
            dependencies: [
                "Domain",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Persistence",
            dependencies: ["Domain"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "SecurityStore",
            dependencies: ["Domain"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Diagnostics",
            dependencies: ["Domain"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Summary",
            dependencies: ["Domain"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "OverlayReducer",
            dependencies: ["Domain"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CompanionProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CompanionProtocolTests",
            dependencies: ["CompanionProtocol"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DomainTests",
            dependencies: ["Domain"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AudioCaptureTests",
            dependencies: ["AudioCapture"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TranscriptionTests",
            dependencies: ["Transcription"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RealtimeClientTests",
            dependencies: ["RealtimeClient"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OverlayReducerTests",
            dependencies: ["OverlayReducer"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SummaryTests",
            dependencies: ["Summary", "Persistence"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SecurityStoreTests",
            dependencies: ["SecurityStore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DiagnosticsTests",
            dependencies: ["Diagnostics"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RealAPITests",
            dependencies: ["RealtimeClient", "Domain", "Diagnostics"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
