// swift-tools-version: 6.4
import Foundation
import PackageDescription

let minimumIOS = ProcessInfo.processInfo.environment["WRATH_VARIANT"] == "compatibility" ? "17.0" : "26.0"

let variantSettings: [SwiftSetting] =
    ProcessInfo.processInfo.environment["WRATH_VARIANT"] == "compatibility"
    ? [.define("WRATH_COMPATIBILITY")] : []

let package = Package(
    name: "Wrath", platforms: [.iOS(minimumIOS)],
    products: [
        .library(name: "Wrath", targets: ["Wrath"]),
        .library(name: "WrathBridge", targets: ["WrathBridge"]),
    ],
    dependencies: [.package(path: "Core"), .package(path: "Dependencies/FFmpegBuild")],
    targets: [
        .binaryTarget(name: "Python", path: "Dependencies/Python.xcframework"),
        .target(
            name: "WrathBridge", dependencies: ["Python", .product(name: "AetherFFmpegBuild", package: "FFmpegBuild")],
            path: "Sources/WrathBridge"),
        .target(
            name: "Wrath", dependencies: ["WrathBridge", .product(name: "WrathCore", package: "Core")],
            path: "Wrath", exclude: ["Info.plist", "Resources", "PrivacyInfo.xcprivacy"],
            swiftSettings: variantSettings
        ),
    ], swiftLanguageModes: [.v5]
)
