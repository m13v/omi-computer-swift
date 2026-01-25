// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OMI-COMPUTER",
    platforms: [
        .macOS("15.0")
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.0.0"),
        .package(url: "https://github.com/mixpanel/mixpanel-swift.git", from: "4.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "OMI-COMPUTER",
            dependencies: [
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "Mixpanel", package: "mixpanel-swift"),
            ],
            path: "Omi/Sources",
            resources: [
                .process("GoogleService-Info.plist"),
                .process("Resources")
            ]
        )
    ]
)
