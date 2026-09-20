// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ScrcpyViewer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ScrcpyViewer", targets: ["ScrcpyViewer"]),
        .library(name: "ViewerCore", targets: ["ViewerCore"]),
    ],
    targets: [
        .target(name: "ViewerCore"),
        .executableTarget(name: "ScrcpyViewer", dependencies: ["ViewerCore"]),
        .testTarget(name: "ViewerCoreTests", dependencies: ["ViewerCore"]),
    ]
)
