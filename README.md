# CKSwiftData

[![Tests](https://github.com/stalkermv/CKSwiftData/actions/workflows/tests.yml/badge.svg)](https://github.com/stalkermv/CKSwiftData/actions/workflows/tests.yml)
[![Swift 6.1+](https://img.shields.io/badge/Swift-6.1+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-iOS%2017%2B%20%7C%20macOS%2014%2B%20%7C%20tvOS%2017%2B%20%7C%20watchOS%2010%2B-lightgrey.svg)](https://developer.apple.com/swift/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Macro-powered CloudKit models with SwiftData-inspired ergonomics.

- Declare models with `@CloudModel`, `@Attribute`, and `@Relationship`
- Persist through an explicit, injected CloudKit database client; property getters never perform network I/O
- Save, fetch, roll back, and resolve conflicts through a main-actor `CloudModelContext`
- Test without CloudKit using deterministic in-memory and scripted clients

> [!WARNING]
> CKSwiftData is pre-1.0 and its API may change between minor releases.
> Behavior against a live CloudKit container is not covered by automated tests
> yet, and predicate/sort queries, shared-zone discovery, operator-driven
> migration backfills, and removal of the legacy `BackingData` layer are not
> supported. See [Status and coverage](#status-and-coverage) for details.

## Installation

Add `CKSwiftData` to your `Package.swift`:

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

Prefer `.upToNextMinor` while the API stabilizes. The package exposes the
`CKSwiftData` library; its `CKSwiftDataMacros` compiler plugin is used
automatically when you apply the macros.

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

## Usage

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

### Schema Metadata

Every `@CloudModel` exposes static `schemaMetadata` describing its attributes and relationships. You can inspect it for migrations, validation, or generating CloudKit dashboards.

```swift
for property in Project.schemaMetadata {
    print("\(property.name): \(String(describing: property.metadata))")
}
```

The backing types live under `Schema.Attribute`, `Schema.Relationship`, and `Schema.PropertyMetadata` for further customization.

## Testing

For tests and previews, inject `CKSwiftDataTesting.InMemoryCloudDatabaseClient`
or `CKSwiftDataTesting.ScriptedCloudDatabaseClient` instead of a
`CloudKitDatabaseClient`. Both are deterministic and never contact CloudKit.

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

## Documentation

DocC documentation lives in the package and can be browsed in Xcode (Product ›
Build Documentation) or built locally:

```bash
swift package --allow-writing-to-directory ./docs \
  generate-documentation --target CKSwiftData \
  --output-path ./docs \
  --transform-for-static-hosting \
  --hosting-base-path CKSwiftData
```

The public contract is summarized in [API_CONTRACT.md](API_CONTRACT.md) and the
design in [ARCHITECTURE.md](ARCHITECTURE.md).

## Development

```bash
swift build -Xswiftc -strict-concurrency=complete
swift test -Xswiftc -strict-concurrency=complete
swiftformat --lint .
```

CKSwiftData supports iOS 17+, macOS 14+, tvOS 17+, and watchOS 10+. CI runs the
host tests, compiles the package for each Apple platform, and builds the
documentation. Tests run against the in-memory and scripted clients; they do not
talk to a live CloudKit container. See [CONTRIBUTING.md](CONTRIBUTING.md) for
the full workflow and [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## Release

Release tags follow plain semver without a `v` prefix, for example `0.2.0`.
CKSwiftData is published as a source-only Swift Package; it does not ship
binary artifacts. See [CHANGELOG.md](CHANGELOG.md) for release notes.

## License

CKSwiftData is available under the MIT license. See [LICENSE](LICENSE).
