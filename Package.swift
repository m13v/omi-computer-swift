// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OMI-COMPUTER",
    platforms: [
        .macOS("15.0")
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "OMI-COMPUTER",
            dependencies: [
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
            ],
            path: "Omi/Sources",
            resources: [
                .process("GoogleService-Info.plist")
            ]
        )
    ]
)
