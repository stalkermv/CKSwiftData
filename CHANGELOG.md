# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Typed CloudKit identities (container, zone, record, and model identifiers)
  and immutable, validated schema manifests with deterministic `Codable`
  encoding.
- Typed record boundary (`CloudRecordValue`, `CloudRecordSnapshot`,
  `CloudRecordMutation`) with request validation, explicit complete and partial
  modification outcomes, and a deterministic JSON codec for custom `Codable`
  values.
- `CloudKitRecordStore` actor and main-actor `CloudModelContext` /
  `CloudModelContainer` with an identity map, change tracking, rollback,
  projected (partial) fetches, upsert/update semantics, and optimistic conflict
  handling.
- `CloudKitDatabaseClient`, an explicit CloudKit adapter with an injected
  `CKDatabase`, cursor routing, and per-record failures.
- Retry policies that classify transient `CKError` cases, honor retry-after
  delays, and propagate cancellation.
- Asset staging with ownership leases, cancellation-safe cleanup, and explicit
  uploads for `@Attribute(.externalStorage)` fields.
- Canonical relationship edge records with a graph planner, edge reader, and
  explicit delete-rule plans.
- Migration compatibility planning, required-field backfill stages, and a
  checkpoint coordinator with an injectable stage executor.
- `CKSwiftDataTesting.InMemoryCloudDatabaseClient` and a scripted client for
  tests and previews.
- `CKSwiftDataPerformance` benchmark executable, a performance test target, and
  a Time Profiler script.
- `swiftformat` configuration and API contract and architecture documents.
- DocC documentation catalog (guides for getting started, modeling, testing,
  relationships and migrations, and the legacy layer), published to GitHub
  Pages by a documentation workflow, and a `swift-docc-plugin` dependency to
  build it.
- Issue and pull request templates.

### Changed
- Rewrote the `@CloudModel`, `@Attribute`, and `@Relationship` macros to
  generate typed storage and schema metadata. `@Relationship` takes an
  `inverseName` for cross-model declarations.
- CI now builds and tests with complete strict concurrency checking, compiles
  the package for iOS, tvOS, watchOS, and macOS, and builds the documentation.
- `Package.resolved` is no longer tracked.

### Fixed
- Temporary files for legacy `@Attribute(.externalStorage)` assets now use a
  unique location per write, so repeated or concurrent writes no longer
  overwrite each other. Encoding and write failures stop with a descriptive
  message instead of an unlabeled `try!` crash.
- Failed record fetches in the legacy `CKDatabase.records(of:matching:)` helper
  are logged through `os.Logger` instead of `print`.

### Removed
- The `swift-collections` and `SwiftHelpers` package dependencies.
- The demo `User` model that was declared in the library target.
