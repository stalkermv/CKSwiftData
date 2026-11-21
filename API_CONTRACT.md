# CKSwiftData 1.0 API Contract

This is the public pre-1.0 API contract. It is explicit about the production
boundaries that still require an application-specific operator or live CloudKit
verification.

## Model declaration surface

```swift
@CloudModel(recordType: "Project", schemaVersion: 1)
@MainActor
final class Project {
    @Attribute(.allowsCloudEncryption, originalName: "name")
    var title: String

    @Relationship(deleteRule: .cascade, inverseName: "project")
    var tasks: [TodoItem] = []

    @Transient
    var isExpanded = false
}
```

The macros must generate typed storage and diagnostics, not generic overload
selection. Persisted members are stored properties with explicit types. Static,
computed, lazy, weak, custom-accessor, unsupported, and ambiguous members are
diagnosed at the declaration site.

## Required public types

### Schema and identity

- `CloudModelIdentifier`, `CloudRecordIdentifier`, and zone/container identifiers
- `CloudSchema`, `CloudModelSchema`, `CloudFieldSchema`, and relationship schema
- immutable, deterministic `Codable & Hashable & Sendable` schema manifests
- `CloudRecordValue`, `CloudRecordSnapshot`, `CloudRecordMutation`, and typed
  fetch/page/modify boundary values
- `CloudRecordValueCodec` and deterministic JSON codec for custom Codable values

### Runtime and persistence

- `CloudPersistentModel`
- `CloudModelContainer`
- `CloudModelContext`
- `CloudStoreConfiguration` and legal database/zone location values
- `CloudFetchDescriptor<Model>` with desired fields, limits, and opaque cursors
- typed complete/partial save and delete results
- `CloudModelError` with record, zone, retry, conflict, and partial-failure context

### Relationships and conflicts

- `CloudRelationshipState<Value>` and relationship edge query/page types
- typed cardinality, ordering, inverse, and delete-rule values
- `CloudConflict<Model>` and `CloudConflictResolver`
- immutable ancestor/client/server snapshots

### Migrations and testing

- `CloudMigrationPlan`, stages, compatibility classification, and checkpoints
- `CloudMigrationStageExecutor` and `CloudMigrationCoordinator`
- `CloudDatabaseClient` production adapter boundary
- `CKSwiftDataTesting.InMemoryCloudDatabaseClient` and scripted failure driver

Raw public `BackingData`, direct `CKDatabase.save(model:)`, `Any` relationship
storage, `_SwiftDataNoType`, and implicit `CKContainer.default()` are not part
of the 1.0 contract.

## Coverage map

### Implemented

- Swift Package manifest and platform declarations.
- Macros and the compiler plugin for `@CloudModel`, `@PersistedProperty`,
  `@Attribute`, `@Relationship`, and `@Transient`.
- A tested scalar `@CloudModel` consumer fixture with generated default
  initialization, explicit record type/schema version, and legacy attribute
  metadata projection.
- Legacy scalar `CKRecord` backing and a typed query helper.
- Schema metadata and observation support for macro-generated models.
- Typed scalar/reference/asset record boundary, request validation, and explicit
  complete/partial modification outcomes.
- Deterministic actor-isolated in-memory and scripted clients for pagination,
  desired fields, optimistic conflicts, deletion, retries, and atomic/non-atomic
  batches.
- Main-actor identity/change contexts, typed model container, rollback, and
  conflict resolution.
- Explicit CloudKit adapter with injected `CKDatabase`, cursor routing,
  per-record failures, and staged asset uploads.
- Relationship edge cursors are scoped to their source and relationship in
  addition to the underlying model/field selection.
- Deterministic relationship edge planning/reading and explicit delete-rule
  plans. `CloudModelContext.delete` does not automatically apply a graph plan.
- Migration compatibility planning, required-field backfill stages, and a
  checkpoint coordinator with executor injection.

Projected fetches (`desiredFields`) are explicit partial snapshots. The record
context merges returned fields without treating omitted fields as deletions and
marks the resulting baseline partial; a typed full-model save therefore requires
one full refresh first. Low-level `CloudRecordMutation` writes remain safe because
they send only their explicit values/removals.

Bound model setters are captured against the clean baseline across a subsequent
typed fetch or non-discarding refresh, including edits made while the async
request is in flight, so an unsaved local edit is not overwritten by the server
echo. An `insert` or `upsert` mutation must include every required schema field;
use `update` for a partial write to an existing record.

`refresh(discardLocalChanges: true)` requires a full field selection. A projected
refresh cannot prove that omitted direct edits were discarded, so it fails closed
with `partialRefreshRequiresFullFetch`. For a full refresh, edits already present
when the request starts are discarded; a newer direct edit made while the request
is in flight is preserved and rebased. An explicit discard refresh has priority
over overlapping ordinary fetches for affected record IDs/pages, so a later
non-discard response cannot silently cancel the requested rollback; unrelated
records and pages continue to merge. A successful save that wins the server
race after rollback is promoted to the current baseline and reattaches the
model; explicit detach supersedes already-started fetch/save responses. A
direct edit made after rollback of an already-applied delete is staged as a
strict insert, so a concurrent recreation is reported as a conflict. A newer
authoritative fetch snapshot also supersedes an older save outcome. If an
overlapping typed fetch stages multiple local fields, the discard removes only
fields that existed at discard start and rebases newer
fields onto the returned server snapshot. Stale fetch/save responses are
generation-filtered before they update identity-map state; the raw page/result
is still returned to its caller.

### Planned / not yet supported (explicit boundary)

- Automatic inverse relationship graph hydration and context-level delete-rule
  execution; loaded record references are preserved, while graph hydration and
  delete plans remain explicit operations.
- Predicate/sort fetch descriptors and durable CloudKit cursor restoration
  across process recreation. CloudKit adapter cursors are process-scoped and
  bound to their model/field selection.
- Global stable ordering of paged relationship edges; the current reader sorts
  each returned remote prefix until a server-side sort descriptor is part of
  the fetch contract.
- Application-specific CloudKit migration executors (backfill transforms,
  dual-read/dual-write, verification queries, and operator deployment).
- Live development-container integration tests and the complete Apple runtime
  matrix.
- Retirement or full hardening of the legacy raw `BackingData` API.

No item in this section may be represented as a successful no-op, empty value,
or silently ignored parameter in the finished public API.

### Not in the 1.0 roadmap

- Transparent synchronous network faulting from a property getter.
- A hidden offline-first/background sync product based on `CKSyncEngine`.
- Automatic destructive production CloudKit schema or index deletion.
- Global atomic transactions for graphs larger than CloudKit request limits.
- CloudKit mutations made outside `CloudModelContext` receiving library-managed
  delete-rule guarantees.

## Contract examples

```swift
@MainActor
func makeContainer(client: any CloudDatabaseClient) throws -> CloudModelContainer {
    let schema = try CloudSchema(models: [
        Project.cloudModelSchema(),
        TodoItem.cloudModelSchema()
    ])
    let configuration = CloudStoreConfiguration(
        containerIdentifier: try CloudContainerIdentifier("iCloud.com.example.App"),
        location: .privateDatabase(.custom(try CloudZoneIdentifier("AppData")))
    )
    return try CloudModelContainer(
        schema: schema,
        configuration: configuration,
        client: client
    )
}

@MainActor
func saveProject(in container: CloudModelContainer) async throws {
    let project = Project()
    project.title = "Roadmap"
    let context = container.mainContext
    try context.insert(project)
    try await context.save()

    let page = try await context.fetch(
        try CloudFetchDescriptor<Project>(limit: 100)
    )
    _ = page.nextCursor
}
```

## 1.0 release criteria

The public 1.0 contract is complete only when all of these are true:

- a clean clone builds with complete Swift 6 strict-concurrency checking;
- macro success and diagnostic fixtures cover the supported declaration matrix;
- every supported field and relationship combination has focused tests;
- all implemented fetch/save/delete parameters reach the driver unchanged;
- conflicts, retries, cancellation, assets, migrations, and partial outcomes
  have deterministic tests;
- no public stub or silent capability default remains in the typed runtime;
  the legacy `BackingData` layer still stops on type mismatches via preconditions and is not
  part of the supported surface;
- README, DocC articles, the migration guide, and schema setup are truthful;
- the agreed Apple platform matrix and isolated CloudKit development smoke
  checks pass.
