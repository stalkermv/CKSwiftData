# Testing

Exercise persistence logic without a CloudKit container.

## In-memory client

``CKSwiftDataTesting`` provides deterministic ``CloudDatabaseClient``
implementations. `InMemoryCloudDatabaseClient` stores records in an actor and
supports paging, projected fields, optimistic conflicts, deletion, and atomic or
non-atomic writes. Inject it where you would inject a ``CloudKitDatabaseClient``.

```swift
let configuration = CloudStoreConfiguration(
    containerIdentifier: try CloudContainerIdentifier("iCloud.com.example.App"),
    location: .privateDatabase(.default)
)
let schema = try CloudSchema(models: [Folder.cloudModelSchema()])
let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
let container = try CloudModelContainer(
    schema: schema,
    configuration: configuration,
    client: client
)

let folder = Folder()
folder.title = "Fixture"
try container.mainContext.insert(folder)
_ = try await container.mainContext.save()
```

## Scripted client

`ScriptedCloudDatabaseClient` wraps another client and lets a test queue
failures for the next fetch or modify call, which makes retry and error
handling deterministic.

## What tests do not cover

The in-memory and scripted clients do not talk to CloudKit. They do not
reproduce server-side behavior such as quotas, schema deployment, or
subscription delivery. Validate those against a CloudKit development container.
