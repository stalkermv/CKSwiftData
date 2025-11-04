# CKSwiftData

[![Tests](https://github.com/stalkermv/CKSwiftData/actions/workflows/tests.yml/badge.svg)](https://github.com/stalkermv/CKSwiftData/actions/workflows/tests.yml)
[![Swift 6.1+](https://img.shields.io/badge/Swift-6.1+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014%20%7C%20tvOS%2017%20%7C%20watchOS%2010-lightgrey.svg)](https://developer.apple.com)

Macro-powered CloudKit models with SwiftData-inspired ergonomics. Annotate your classes with `@CloudModel` and let CKSwiftData generate CloudKit plumbing, record metadata accessors, schema information, and persistence helpers that feel just like SwiftData – but for CloudKit.

- 📚 **Documentation** – Rich inline docs and DocC comments for public APIs
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
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

## Overview

CKSwiftData bridges the gap between SwiftData's expressive model syntax and CloudKit's remote persistence. You write familiar SwiftData-style model code; CKSwiftData handles the macros, backing storage, and CloudKit record interactions under the hood.

The package exposes two modules:

- `CKSwiftData` – Public macros and runtime helpers used by your app
- `CKSwiftDataMacros` – Compiler plugin that powers macro expansion (imported automatically when you use the macros)

## Features

- ✅ **`@CloudModel` macro** – Generates CloudKit boilerplate, including backing storage, observation support, and schema metadata.
- ✅ **`@PersistedProperty` macro** – Synthesizes accessors that read/write from CloudKit records and integrates with Swift observation.
- ✅ **`@Attribute` options** – Configure CloudKit fields (original names, hashing modifiers, external storage, and more).
- ✅ **`@Relationship` macro** – Model CloudKit references with convenient projected values and delete rules.
- ✅ **Schema-aware runtime** – `Schema.PropertyMetadata` and `Schema.Relationship` describe your model for migrations, tooling, or validation.
- ✅ **CloudKit helpers** – Save, delete, and fetch typed models using extensions on `CKDatabase` and `CKQuery`.
- ✅ **Observation integration** – Generated code uses `ObservationRegistrar` so SwiftUI updates automatically when records change.

## Installation

Add CKSwiftData to your `Package.swift`:

```swift
// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    // ...
    dependencies: [
        .package(url: "https://github.com/stalkermv/CKSwiftData.git", .upToNextMinor(from: "0.1.0"))
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

@CloudModel
final class Folder {
    var title: String
    var color: String?
    @Relationship(deleteRule: .cascade) var snippets: [Snippet]
}

@CloudModel
final class Snippet {
    var text: String
    var lastUpdated: Date
    @Relationship(inverse: \Snippet.folder) var folder: Folder?
}
```

### 2. Work with models just like SwiftData

```swift
let folder = Folder()
folder.title = "My Ideas"

let database = CKContainer.default().publicCloudDatabase
let savedFolder = try await database.save(folder)
```

### 3. Fetch back strongly-typed models

```swift
let query = CKQuery(recordType: Folder.self, predicate: NSPredicate(value: true))
let (folders, cursor) = try await database.records(of: Folder.self, matching: query)
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

The generated accessors automatically encode/decode values through `CKAsset` when `.externalStorage` is set.

### Relationships

`@Relationship` manages CloudKit references for working with models.

```swift
@CloudModel
final class Project {
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \Task.project) var tasks: [Task]
}

@CloudModel
final class Task {
    var title: String
    @Relationship var project: Project?
}

task.project = project
```

### CloudKit Persistence

Once you obtain a `CKDatabase`, you can persist models using familiar async APIs:

```swift
let database = CKContainer.default().publicCloudDatabase
let project = try await database.save(project)

try await database.delete(task)
```

Behind the scenes, CKSwiftData keeps CloudKit references in sync and stores relationship backing data so you can traverse the graph locally.

## Schema Metadata

Every `@CloudModel` exposes static `schemaMetadata` describing its attributes and relationships. You can inspect it for migrations, validation, or generating CloudKit dashboards.

```swift
for property in Project.schemaMetadata {
    print("\(property.name): \(property.metadata)")
}
```

The backing types live under `Schema.Attribute`, `Schema.Relationship`, and `Schema.PropertyMetadata` for further customization.

## Roadmap

- 🔄 Relationship collections for arbitrarily large to-many sets
- 🧪 Comprehensive unit tests covering macro expansions
- 🛠️ Schema tooling for migrating CloudKit containers
- 📄 DocC documentation bundle

See [CHANGELOG.md](CHANGELOG.md) for released versions and detailed notes.

## Contributing

Contributions are very welcome! Check out [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines, development workflow, and contact information. Security issues? Please follow the process in [SECURITY.md](SECURITY.md).

## License

CKSwiftData is released under the [MIT License](LICENSE).

