// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Jayson",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JaysonCore", targets: ["JaysonCore"]),
        .executable(name: "Jayson", targets: ["Jayson"]),
        .executable(name: "JaysonCoreChecks", targets: ["JaysonCoreChecks"]),
    ],
    targets: [
        .target(name: "JaysonCore", path: "Sources/JaysonCore"),
        .executableTarget(
            name: "Jayson",
            dependencies: ["JaysonCore"],
            path: "Sources/Jayson"
        ),
        // Lightweight test runner (`swift run JaysonCoreChecks`). Used instead of XCTest/Testing
        // because those frameworks are not available with Command Line Tools alone.
        .executableTarget(name: "JaysonCoreChecks", dependencies: ["JaysonCore"], path: "Sources/JaysonCoreChecks"),
    ]
)
