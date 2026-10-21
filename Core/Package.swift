// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "WrathCore",
    platforms: [.iOS("17.0"), .macOS(.v14)],
    products: [.library(name: "WrathCore", targets: ["WrathCore"])],
    targets: [.target(name: "WrathCore")])
