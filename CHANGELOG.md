# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial documentation scaffold and community health files
- CI workflow that builds and tests the package on macOS with Swift 6.1
- README with quick-start examples for using the macros

## [0.1.0] - 2025-02-26

### Added
- `@CloudModel` macro that synthesizes CloudKit backing storage and schema metadata
- `@PersistedProperty`, `@Attribute`, and `@Relationship` macros for describing CloudKit fields
- Runtime support for CloudKit-backed models, including `CKDatabase` helpers and schema types

[Unreleased]: https://github.com/stalkermv/CKSwiftData/compare/0.1.0...HEAD
[0.1.0]: https://github.com/stalkermv/CKSwiftData/releases/tag/0.1.0
