// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Wrath", platforms: [.iOS("27.0")],
    products: [
        .library(name: "Wrath", targets: ["Wrath"]),
        .library(name: "WrathBridge", targets: ["WrathBridge"]),
    ],
    dependencies: [.package(path: "Core"), .package(path: "Dependencies/FFmpegBuild")],
    targets: [
        .binaryTarget(name: "Python", path: "Dependencies/Python.xcframework"),
        .target(
            name: "WrathBridge", dependencies: ["Python", .product(name: "AetherFFmpegBuild", package: "FFmpegBuild")],
            path: "Sources/WrathBridge", linkerSettings: [.linkedFramework("JavaScriptCore")]),
        .target(
            name: "Wrath", dependencies: ["WrathBridge", .product(name: "WrathCore", package: "Core")],
            path: "Wrath", exclude: ["Info.plist", "Resources", "PrivacyInfo.xcprivacy"]),
    ], swiftLanguageModes: [.v5]
)
