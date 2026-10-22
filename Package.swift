// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VMSNext",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VMSNext",
            path: "Sources/VMSNext",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ],
    swiftLanguageModes: [.v5]
)
