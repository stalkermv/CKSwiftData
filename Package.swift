// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "CKSwiftData",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "CKSwiftData", targets: ["CKSwiftData"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "601.0.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.2.0"),
        .package(url: "https://github.com/stalkermv/SwiftHelpers.git", from: "1.0.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "CKSwiftData",
            dependencies: [
                "CKSwiftDataMacros",
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "SwiftHelpers", package: "SwiftHelpers")
            ]
        ),
        .macro(
            name: "CKSwiftDataMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                // Added explicit dependencies to resolve linker undefined symbols
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax")
            ]
        ),
        .testTarget(
            name: "CKSwiftDataTests",
            dependencies: ["CKSwiftData"]
        ),
    ]
)
