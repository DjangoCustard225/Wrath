// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "WrathCore",
    platforms: [.iOS("27.0"), .macOS(.v14)],
    products: [.library(name: "WrathCore", targets: ["WrathCore"])],
    targets: [.target(name: "WrathCore")])
