# CKSwiftData

[![Tests](https://github.com/stalkermv/CKSwiftData/actions/workflows/tests.yml/badge.svg)](https://github.com/stalkermv/CKSwiftData/actions/workflows/tests.yml)
[![Swift 6.2+](https://img.shields.io/badge/Swift-6.2+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-iOS%2017%2B%20%7C%20macOS%2014%2B%20%7C%20tvOS%2017%2B%20%7C%20watchOS%2010%2B-lightgrey.svg)](https://developer.apple.com/swift/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Declare CloudKit models with macros, in the style of SwiftData. Save and fetch them through a context that you can test without CloudKit.

- Declare models with `@CloudModel`, `@Attribute`, and `@Relationship`
- Save and fetch through a main-actor `CloudModelContext`
- Inject the database client explicitly; property getters never use the network
- Get typed fetch pages, save results, and conflict errors
- Test with in-memory and scripted clients

## Requirements

- Swift 6.2 or later
- iOS 17, macOS 14, tvOS 17, or watchOS 10 and later

## Installation

Add CKSwiftData to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/stalkermv/CKSwiftData.git", .upToNextMinor(from: "0.2.0"))
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "CKSwiftData", package: "CKSwiftData")
        ]
    )
]
```

## Quick Start

```swift
import CKSwiftData
import CloudKit

@CloudModel(schemaVersion: 1)
final class Folder {
    var title: String = ""
    var color: String?
    @Relationship(deleteRule: .cascade, inverse: \Note.folder)
    var notes: [Note] = []
}

@CloudModel
final class Note {
    var text: String = ""
    @Relationship var folder: Folder?
}

@MainActor
func run() async throws {
    let configuration = CloudStoreConfiguration(
        containerIdentifier: try CloudContainerIdentifier("iCloud.com.example.App"),
        location: .privateDatabase(.default)
    )
    let schema = try CloudSchema(models: [
        Folder.cloudModelSchema(),
        Note.cloudModelSchema()
    ])
    let database = CKContainer(identifier: configuration.containerIdentifier.rawValue)
        .privateCloudDatabase
    let client = try CloudKitDatabaseClient(
        schema: schema,
        configuration: configuration,
        database: database
    )
    let container = try CloudModelContainer(
        schema: schema,
        configuration: configuration,
        client: client
    )
    let context = container.mainContext

    // Save a new folder with a note.
    let folder = Folder()
    folder.title = "My Ideas"
    let note = Note()
    note.text = "Write a README"
    note.folder = folder
    try context.insert(folder)
    try context.insert(note)
    let result = try await context.save()
    print("Failed records: \(result.failures.count)")

    // Fetch folders back.
    let page = try await context.fetch(try CloudFetchDescriptor<Folder>(limit: 100))
    print("Fetched \(page.models.count) folders")
}
```

The record type is the class name. To use another name, write `@CloudModel(recordType: "Folder")`. Set it explicitly for models that are already in production: renaming the class changes the record type in CloudKit.

Name the inverse of a relationship on one side only, with a key path such as `\Note.folder`. The other side is filled in for you. If you put a key path on both sides, the compiler reports a circular reference. You can also name both sides with strings: `@Relationship(inverseName: "folder")`.

## Testing

Use `CKSwiftDataTesting.InMemoryCloudDatabaseClient` in place of `CloudKitDatabaseClient`. It stores records in memory and never contacts CloudKit. `ScriptedCloudDatabaseClient` wraps another client and fails calls on demand, so you can test error handling.

## Documentation

The DocC documentation is published at [stalkermv.github.io/CKSwiftData](https://stalkermv.github.io/CKSwiftData/documentation/ckswiftdata/). It covers models, relationships, testing, and migrations. See also [API_CONTRACT.md](API_CONTRACT.md) and [ARCHITECTURE.md](ARCHITECTURE.md).

## Status

CKSwiftData is pre-1.0. The API can change between minor releases. These parts are not supported yet:

- Tests against a live CloudKit container (all tests use in-memory clients)
- Predicate and sort queries
- Shared databases in the CloudKit client
- Ready-made migration backfills
- Removal of the legacy `BackingData` layer

## Development

```bash
swift build -Xswiftc -strict-concurrency=complete
swift test -Xswiftc -strict-concurrency=complete
swiftformat --lint .
```

## Release

Releases use plain version tags such as `0.2.0`. See [CONTRIBUTING.md](CONTRIBUTING.md) for the process and [CHANGELOG.md](CHANGELOG.md) for release notes.

## License

CKSwiftData is available under the MIT license. See [LICENSE](LICENSE).
