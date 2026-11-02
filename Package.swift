// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "astro-a50",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "A50Kit", targets: ["A50Kit"]),
        .executable(name: "a50ctl", targets: ["a50ctl"]),
        .executable(name: "A50Control", targets: ["A50Control"]),
    ],
    targets: [
        .target(name: "A50Kit"),
        .executableTarget(name: "a50ctl", dependencies: ["A50Kit"]),
        .executableTarget(name: "A50Control", dependencies: ["A50Kit"]),
    ]
)
