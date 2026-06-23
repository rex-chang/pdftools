// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDFMerge",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(
            name: "PDFMerge",
            path: "Sources/PDFMerge"
        ),
        .testTarget(
            name: "PDFMergeTests",
            dependencies: ["PDFMerge"],
            path: "Tests/PDFMergeTests"
        ),
    ]
)
