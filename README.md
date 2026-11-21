# CKSwiftData

> [!WARNING]
> This project is in an early stage of development and is not ready for production use. APIs and behavior may change without notice. Use at your own risk.

> [!IMPORTANT]
> CKSwiftData is pre-1.0 and its API may change between minor releases.
> Behavior against a live CloudKit container is not covered by automated tests
> yet, and predicate/sort queries, shared-zone discovery, operator-driven
> migration backfills, and removal of the legacy `BackingData` layer are not
> supported. See [Status and coverage](#status-and-coverage) for details.

[![Tests](https://github.com/stalkermv/CKSwiftData/actions/workflows/tests.yml/badge.svg)](https://github.com/stalkermv/CKSwiftData/actions/workflows/tests.yml)
[![Swift 6.1+](https://img.shields.io/badge/Swift-6.1+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014%20%7C%20tvOS%2017%20%7C%20watchOS%2010-lightgrey.svg)](https://developer.apple.com)

Macro-powered CloudKit models with SwiftData-inspired ergonomics. Annotate your classes with `@CloudModel` and let CKSwiftData generate CloudKit plumbing, record metadata accessors, schema information, and persistence helpers that feel just like SwiftData – but for CloudKit.

- 📚 **Documentation** – Inline documentation comments for public APIs
- 💡 **Examples** – See [Quick Start](#quick-start) and [Usage Examples](#usage-examples)
- 🤝 **Contributions** – Always welcome! See [CONTRIBUTING.md](CONTRIBUTING.md)
- 🪪 **License** – MIT License, see [LICENSE](LICENSE)

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Usage Examples](#usage-examples)
  - [Persisted Attributes](#persisted-attributes)
  - [Relationships](#relationships)
  - [CloudKit Persistence](#cloudkit-persistence)
- [Schema Metadata](#schema-metadata)
- [Status and coverage](#status-and-coverage)
- [Development checks](#development-checks)
- [Contributing](#contributing)
- [License](#license)

## Overview

CKSwiftData bridges the gap between SwiftData's expressive model syntax and CloudKit's remote persistence. You write familiar SwiftData-style model code; CKSwiftData handles the macros, backing storage, and CloudKit record interactions under the hood.

The package exposes two modules:

- `CKSwiftData` – Public macros and runtime helpers used by your app
- `CKSwiftDataMacros` – Compiler plugin that powers macro expansion (imported automatically when you use the macros)

## Features

- ✅ **`@CloudModel` / `@Attribute` / `@Relationship`** – Macro expansion,
  typed metadata, defaults, bounds, and explicit inverse names.
- ✅ **Schema-aware runtime** – Immutable validated manifests and typed record
  values/codecs.
- ✅ **Contexts and store** – Actor persistence, main-actor identity map,
  rollback, partial outcomes, conflicts, retries, and typed container APIs.
- ✅ **CloudKit adapter and assets** – Explicit database injection, cursor
  routing, per-record failures, staging leases, and upload binding.
- ✅ **Relationship and migration planning** – Deterministic edge plans,
  delete rules, compatibility classification, and checkpoint coordination.
- 🚧 **Production operations** – Live CloudKit smoke tests, application-specific
  migration executors, and legacy backing-layer retirement are planned.

## Installation

Add CKSwiftData to your `Package.swift`:

```swift
// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    // ...
    dependencies: [
        .package(url: "https://github.com/stalkermv/CKSwiftData.git", .upToNextMinor(from: "0.2.0"))
    ],
    targets: [
        .target(
            name: "YourFeatureModule",
            dependencies: [
                .product(name: "CKSwiftData", package: "CKSwiftData")
            ]
        ),
    ]
)
```

Then import CKSwiftData where you declare models:

```swift
import CKSwiftData
```

> **Tip:** While APIs stabilize, prefer `.upToNextMinor` requirements to avoid unexpected breaking changes.

## Quick Start

### 1. Declare a CloudKit model

```swift
import CKSwiftData
import CloudKit

@CloudModel(recordType: "Folder", schemaVersion: 1)
final class Folder {
    var title: String = ""
    var color: String?
    @Relationship(deleteRule: .cascade, inverseName: "folder")
    var snippets: [Snippet] = []
}

@CloudModel
final class Snippet {
    var text: String = ""
    var lastUpdated: Date = Date()
    @Relationship(inverseName: "snippets") var folder: Folder?
}
```

Cross-model key-path expressions can create compiler circular-reference
diagnostics in Swift macro expansion; use `inverseName` when the inverse is in
another declaration.

### 2. Assemble an explicit container

```swift
let folder = Folder()
folder.title = "My Ideas"

let configuration = CloudStoreConfiguration(
    containerIdentifier: try CloudContainerIdentifier("iCloud.com.example.App"),
    location: .privateDatabase(.default)
)
let schema = try CloudSchema(models: [
    Folder.cloudModelSchema(),
    Snippet.cloudModelSchema()
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
try container.mainContext.insert(folder)
let result = try await container.mainContext.save()
// `result.failures` lists records that could not be saved.
```

For tests and previews, inject `CKSwiftDataTesting.InMemoryCloudDatabaseClient`
instead of constructing a CloudKit client.

### 3. Fetch back strongly-typed models

```swift
let page = try await container.mainContext.fetch(
    try CloudFetchDescriptor<Folder>(limit: 100)
)
let folders = page.models
let cursor = page.nextCursor
```

## Usage Examples

### Persisted Attributes

CKSwiftData handles default values, optional storage, and assets when you opt into `@Attribute(.externalStorage)`.

```swift
@CloudModel
final class AssetExample {
    @Attribute(.externalStorage)
    var payload: Data
}
```

The schema marks the field as an asset. Uploads use an explicit
`CloudAssetStager` lease and the `CloudKitDatabaseClient` asset overload; a
model getter never performs an implicit download.

### Relationships

`@Relationship` manages CloudKit references for working with models.

```swift
@CloudModel
final class Project {
    var name: String = ""
    @Relationship(deleteRule: .cascade, inverseName: "project")
    var tasks: [TodoItem] = []
}

@CloudModel
final class TodoItem {
    var title: String = ""
    @Relationship(inverseName: "tasks") var project: Project?
}

todo.project = project
```

### CloudKit Persistence

Once you inject a `CloudKitDatabaseClient`, persistence stays explicit and
asynchronous:

```swift
try container.mainContext.insert(project)
_ = try await container.mainContext.save()
try container.mainContext.delete(todo)
_ = try await container.mainContext.save()
```

Relationship edge records are planned through `CloudRelationshipGraphPlanner`
and read through `CloudRelationshipEdgeReader`; model collection hydration is
kept explicit rather than performing hidden network I/O from a getter.

## Schema Metadata

Every `@CloudModel` exposes static `schemaMetadata` describing its attributes and relationships. You can inspect it for migrations, validation, or generating CloudKit dashboards.

```swift
for property in Project.schemaMetadata {
    print("\(property.name): \(String(describing: property.metadata))")
}
```

The backing types live under `Schema.Attribute`, `Schema.Relationship`, and `Schema.PropertyMetadata` for further customization.

## Status and coverage

### Implemented

- Typed identities, immutable schema manifests, relationship validation, and
  deterministic JSON record values.
- `@CloudModel`, scalar `@Attribute`, and typed `@Relationship` accessors,
  including explicit `inverseName` metadata for cross-model declarations.
- Actor-isolated `CloudKitRecordStore`, main-actor identity/change contexts,
  typed model container, rollback, partial outcomes, and optimistic conflicts.
- Projected fetches preserve omitted fields as unknown (`isPartial`) and require
  a full refresh before a typed full-model save; explicit field mutations remain
  safe to retry.
- Direct edits on a bound model are captured across a later typed fetch/refresh,
  including edits made while the request is in flight, and `upsert` rejects
  missing required fields (use `update` for partial writes).
- A full discard refresh removes edits present at invocation but preserves a
  newer direct edit made while that refresh is in flight; projected discard
  refreshes fail closed. If a save commits while rollback is in flight, its
  successful server snapshot reattaches the model instead of leaving a silent
  detached no-op. Explicit detach also supersedes already-started fetch/save
  responses, and a newer authoritative fetch snapshot cannot be downgraded by
  an older save. A direct edit after rollback of an already-applied delete is
  staged as a strict insert so concurrent recreation surfaces an explicit
  conflict.
- Deterministic in-memory and scripted clients with paging, projections,
  atomic/non-atomic writes, retry behavior, and cancellation propagation.
- Explicit `CloudKitDatabaseClient` injection, CloudKit record routing,
  pagination cursors, per-record failures, and staged asset uploads.
- Canonical relationship edge planning/reading, explicit delete-rule plans, and
  migration compatibility planning with persisted resumable checkpoints.

Relationship edge pages are filtered client-side and sorted within each remote
prefix. A globally stable order across pages remains gated on a remote sort
descriptor and is not guaranteed.

### Planned / not yet supported

- A production `CloudMigrationStageExecutor` for application-specific
  backfills, dual-read/dual-write windows, and operator deployment.
- Live development-container smoke tests and the complete iOS/tvOS/watchOS
  runtime matrix; automated verification currently runs on macOS only.
- Automatic graph-to-model hydration and context-level delete-rule execution;
  typed accessors preserve loaded references, while canonical edge
  planning/reading remains an explicit integration layer.
- Predicate/sort descriptors for remote fetches and durable CloudKit cursor
  restoration across process recreation.
- Removal or full hardening of the legacy `BackingData`/`CKBackingData` API.

No planned public feature is represented by a silent no-op or empty success.

### Not in the roadmap

- Transparent synchronous network faulting from property getters.
- Hidden offline-first synchronization through `CKSyncEngine`.
- Automatic destructive production CloudKit schema/index deletion.
- Global atomic transactions beyond CloudKit request limits.

## Development checks

```bash
swift build -Xswiftc -strict-concurrency=complete
swift test -Xswiftc -strict-concurrency=complete
swiftformat --lint .
```

Tests run against the in-memory and scripted clients; they do not talk to a
live CloudKit container.

See [CHANGELOG.md](CHANGELOG.md) for release notes.

## Contributing

Contributions are very welcome! Check out [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines, development workflow, and contact information. Security issues? Please follow the process in [SECURITY.md](SECURITY.md).

## License

CKSwiftData is released under the [MIT License](LICENSE).
