# Getting Started

Declare a model, assemble a container, and save and fetch records.

## Add the package

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

## Declare a model

Annotate a class with `@CloudModel`. Persisted members are stored properties
with explicit types.

```swift
import CKSwiftData
import CloudKit

@CloudModel(recordType: "Folder", schemaVersion: 1)
final class Folder {
    var title: String = ""
    var color: String?
}
```

## Assemble a container

A ``CloudModelContainer`` ties a validated ``CloudSchema``, a
``CloudStoreConfiguration``, and a database client together. The database client
is always injected.

```swift
let configuration = CloudStoreConfiguration(
    containerIdentifier: try CloudContainerIdentifier("iCloud.com.example.App"),
    location: .privateDatabase(.default)
)
let schema = try CloudSchema(models: [Folder.cloudModelSchema()])
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
```

## Save and fetch

Contexts are main-actor isolated. Insert models, then save asynchronously:

```swift
let folder = Folder()
folder.title = "My Ideas"

try container.mainContext.insert(folder)
let result = try await container.mainContext.save()
// `result.failures` lists records that could not be saved.

let page = try await container.mainContext.fetch(
    try CloudFetchDescriptor<Folder>(limit: 100)
)
let folders = page.models
let cursor = page.nextCursor
```

``CloudModelContext/save(atomic:retryPolicy:)`` returns a ``CloudModifyResult``
instead of hiding partial failures. ``CloudModelContext/fetch(_:retryPolicy:)`` returns a
``CloudModelPage`` and an opaque cursor for the next page.

## Next steps

- <doc:Modeling> covers attributes, relationships, and schema metadata.
- <doc:Testing> shows how to run the same code against an in-memory client.
