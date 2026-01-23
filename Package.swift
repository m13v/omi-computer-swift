// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OMI",
    platforms: [
        .macOS("15.0")
    ],
    targets: [
        .executableTarget(
            name: "OMI",
            path: "Hartford/Sources"
        )
    ]
)
