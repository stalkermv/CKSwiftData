# ``CKSwiftData``

Declare CloudKit models with macros and persist them through an explicit, testable client.

## Overview

CKSwiftData gives CloudKit models a SwiftData-like declaration style. You
annotate a class with `@CloudModel`, describe its fields with `@Attribute` and
`@Relationship`, and persist it through a main-actor ``CloudModelContext``.

The library keeps the remote boundary explicit:

- Persistence goes through an injected ``CloudDatabaseClient``; CloudKit is never
  reached implicitly and `CKContainer.default()` is not a hidden dependency.
- A property getter never performs network I/O.
- Fetches return typed pages with opaque cursors, and saves return explicit
  complete or partial outcomes.
- Deterministic in-memory and scripted clients let you test persistence logic
  without a CloudKit container.

```swift
import CKSwiftData

@CloudModel(schemaVersion: 1)
final class Folder {
    var title: String = ""
    var color: String?
}
```

> Important: CKSwiftData is pre-1.0. Its API may change between minor releases,
> and behavior against a live CloudKit container is not covered by automated
> tests yet.

## Topics

### Guides

- <doc:GettingStarted>
- <doc:Modeling>
- <doc:Testing>
- <doc:RelationshipsAndMigrations>
- <doc:LegacyBackingData>

### Containers and contexts

- ``CloudModelContainer``
- ``CloudModelContext``
- ``CloudStoreConfiguration``
- ``CloudStoreLocation``
- ``CloudFetchDescriptor``
- ``CloudModelPage``
- ``CloudModifyResult``

### Schema and identity

- ``CloudSchema``
- ``CloudModelSchema``
- ``CloudModelIdentifier``
- ``CloudFieldIdentifier``
- ``CloudRecordIdentifier``
- ``CloudZoneIdentifier``
- ``CloudContainerIdentifier``

### Records and values

- ``CloudRecordSnapshot``
- ``CloudRecordMutation``
- ``CloudRecordValue``
- ``CloudRecordValueCodec``
- ``CloudJSONRecordValueCodec``

### Clients and the store

- ``CloudDatabaseClient``
- ``CloudKitDatabaseClient``
- ``CloudKitRecordStore``
- ``CloudRetryPolicy``

### Conflicts and errors

- ``CloudConflict``
- ``CloudConflictResolver``
- ``CloudModelError``

### Assets

- ``CloudAssetStager``
- ``CloudAssetLease``
- ``CloudAssetUpload``

### Relationships

- ``CloudRelationshipGraphPlanner``
- ``CloudRelationshipEdgeReader``
- ``CloudRelationshipState``
- ``CloudDeleteRule``

### Migrations

- ``CloudMigrationPlan``
- ``CloudMigrationCoordinator``
- ``CloudMigrationStageExecutor``
- ``CloudMigrationCheckpointStore``

### Testing

- ``CKSwiftDataTesting``

### Legacy compatibility layer

- ``BackingData``
- ``CloudKitModel``
