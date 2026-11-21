// swift-tools-version: 6.1

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "CKSwiftData",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "CKSwiftData", targets: ["CKSwiftData"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "601.0.0"),
        // Documentation generation
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "CKSwiftData",
            dependencies: ["CKSwiftDataMacros"]
        ),
        .executableTarget(
            name: "CKSwiftDataPerformance",
            dependencies: ["CKSwiftData"],
            path: "Benchmarks/CKSwiftDataPerformance"
        ),
        .macro(
            name: "CKSwiftDataMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax")
            ]
        ),
        .testTarget(
            name: "CKSwiftDataTests",
            dependencies: ["CKSwiftData"]
        ),
        .testTarget(
            name: "CKSwiftDataPerformanceTests",
            dependencies: ["CKSwiftData"],
            path: "Tests/CKSwiftDataPerformanceTests"
        ),
    ]
)
