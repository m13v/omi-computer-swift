// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OMI",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "OMI",
            path: "Hartford/Sources"
        )
    ]
)
