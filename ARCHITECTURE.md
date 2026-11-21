# CKSwiftData 1.0 Architecture

Status: pre-1.0. The typed runtime described below is implemented and tested;
live CloudKit deployment and application-specific migration work remain open.

## Product boundary

CKSwiftData gives a developer SwiftData-like model declarations for CloudKit:

- `@CloudModel` declares a persistent model and its stable record type.
- `@Attribute` declares a supported CloudKit scalar, encoded value, or asset.
- `@Relationship` declares a typed relationship, inverse, bounds, ordering, and
  delete rule.
- `@Transient` declares state that is observable but never persisted.

The library provides explicit asynchronous fetch, edge loading, save, delete,
conflict, and migration operations. A property getter never performs network I/O. The
SwiftData-like surface is the model declaration and local observation model;
CloudKit's remote failure and pagination semantics remain explicit.

## Layering

```text
Model declarations / macros
          |
Typed schema and model state (@MainActor)
          |
CloudModelContext (identity map, changes, relationship load state)
          |
CloudKitRecordStore (actor: planning, codec, retry, conflicts)
          |
CloudDatabaseClient (Sendable protocol; CloudKit adapter or fake)
          |
CloudKit
```

The public typed facade does not require raw `BackingData`, `Any` relationship
storage, or `_SwiftDataNoType`. Those names remain in the legacy compatibility
surface while the typed runtime is exercised through `CloudModelContext` and
`CloudKitRecordStore`.

## Isolation and state

- Generated mutable models and `CloudModelContext` are `@MainActor`.
- Network and persistence state is owned by an actor.
- Only immutable `Sendable` snapshots, requests, schema values, and typed
  operation results cross the actor boundary.
- No `@unchecked Sendable`, fire-and-forget tasks, or implicit main-actor
  assumptions are allowed.
- Every result that returns after `await` is merged against the context
  generation and baseline that produced the request. A stale result cannot
  overwrite a newer local edit.

Model persistence state is an enum rather than a collection of independent
flags: `detached`, `inserted`, `clean`, `dirty`, and `deleted`. Relationship
state is also explicit: `unloaded`, `loaded`, or `failed`. An unloaded
relationship is not represented as a misleading empty array or `nil`.

## Schema contract

Schema values are immutable, `Codable`, `Hashable`, and `Sendable`. Every model,
field, and relationship has a stable identifier independent of Swift spelling.
Schema validation happens before a CloudKit request and rejects:

- unsupported field types or option combinations;
- duplicate model or field identifiers;
- invalid relationship targets, inverses, or cardinality bounds;
- cross-store or cross-zone relationships;
- renames without an explicit migration identity.

The manifest distinguishes scalar, encoded, asset, to-one, and to-many fields.
It records destination model, inverse identity, optionality, bounds, ordering,
delete rule, and migration aliases. It must not depend on `Any.Type` or runtime
key-path reflection for correctness.

## Values and assets

The codec matrix is explicit and tested for the supported CloudKit
scalars, optionals, homogeneous arrays, assets, and custom `Codable & Sendable`
JSON codecs. Unsupported values fail with a typed error at the codec boundary;
they never fall through to a force cast.

Asset staging uses unique files, ownership/cleanup leases, cancellation-safe
cleanup, and a materialization step for downloaded assets. CloudKit staging URLs
are treated as temporary and may be unavailable on a conflict response.

## Relationships

To-one relationships use a typed CloudKit reference. To-many relationships use
canonical edge records, not an unbounded array of references in the owner
record. Edge identity is deterministic for `(source, relationship, target)`,
which prevents duplicates and enables bounded pagination and many-to-many
relationships. Stable positions are persisted by the planner; the current
reader sorts the returned prefix and deliberately does not claim globally
ordered pages until remote sort descriptors are part of the fetch contract.

Only one side owns persisted relationship edges. `CloudRelationshipGraphPlanner`
computes an old/new diff and creates a cycle-safe persistence plan; materialized
inverse model collections are an explicit integration layer rather than hidden
network faulting in a property getter.

Delete rules are enforced by explicit `CloudRelationshipGraphPlanner`
operations. `CloudModelContext.delete` does not silently synthesize graph
mutations; callers apply the plan explicitly. CloudKit mutations made outside
the library can bypass these guarantees and are documented as such.

## Store and operations

Store configuration is a closed value type. It permits only legal combinations
of database scope, container identifier, and zone. Database and container
clients are injected; `CKContainer.default()` is not a hidden dependency.

Fetches currently use typed descriptors with desired fields, limit, and an
opaque process-scoped cursor. Relationship edge readers wrap that cursor with
the source/relationship scope so it cannot be reused for another edge query.
Projected snapshots merge known fields into the
identity map but retain an `isPartial` baseline marker; typed full-model saves
must perform a full refresh first, while explicit low-level mutations remain
field-scoped. Predicate/sort descriptors are not silently accepted by the
adapter yet. Save/delete return typed complete or partial outcomes and preserve
per-record failures. Conflict handling uses an unchanged-server policy by
default and exposes ancestor/client/server snapshots to a resolver.
Bound model setters are captured against the clean baseline across typed fetches
and non-discarding refreshes, including edits made while the async request is in
flight; `insert`/`upsert` validation requires all required fields while `update`
remains the partial-write policy.
Discarding local changes is allowed only for a full refresh; projected discard
requests fail closed because omitted fields cannot be reset safely. A full
discard refresh drops edits present when it starts, but preserves and rebases a
newer direct edit made while the request is in flight. Discard refreshes have
priority over overlapping ordinary fetches for affected record IDs/pages, while
unrelated records and pages continue to merge. A successful save that wins the
server race after rollback is promoted to the current baseline and reattaches
the model; explicit detach supersedes already-started fetch/save responses. A
direct edit made after rollback of an already-applied delete is staged as a
strict insert, so a concurrent recreation is reported as a conflict. A newer
authoritative fetch snapshot also supersedes an older save outcome. A
discard preserves only fields staged after it began, rebasing them onto the
returned server snapshot; per-record fetch/save generations prevent stale
responses or failures from mutating newer identity-map state.

Retries classify transient `CKError` cases, respect retry-after, have a bounded
budget, and propagate cancellation. A global atomic transaction beyond
CloudKit's request limits is not promised; large operations are resumable.

## Schema evolution

CloudKit production schema changes are coordinated through a checked-in schema
manifest and an operator deployment step. The migration planner supports
additive fields, rename aliases, required-field backfill stages, verification
stages, and persisted checkpoints. A `CloudMigrationStageExecutor` is injected
for transforms, record-type copies, dual-read/dual-write windows, idempotent
backfills, and delayed cleanup. Destructive production field deletion is outside
the client library's automatic scope.

## Legacy `BackingData` layer

The `BackingData`/`CKBackingData` graph predates the typed runtime and is kept
for compatibility. It is not the foundation of the 1.0 runtime. Its raw and
force-cast paths will be replaced by typed layers with focused tests, and the
legacy runtime will be removed or hardened only after the complete 1.0 criteria
pass. New code should use the typed schema, `CloudModelContext`, and
`CloudKitRecordStore`.

No public 1.0 release is cut while a feature is silently stubbed.
