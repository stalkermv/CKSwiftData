# Modeling

Describe fields, relationships, and schema metadata with macros.

## Attributes

Stored properties of a `@CloudModel` class are persisted. Use `@Attribute` to
adjust a field, and `@Transient` to keep a property out of the record.

```swift
@CloudModel(recordType: "Document", schemaVersion: 1)
final class Document {
    @Attribute(.unique, originalName: "legacy_title")
    var title: String = ""

    var note: String?

    @Transient
    var isExpanded = false
}
```

Large payloads can use external storage, which maps the field to a CloudKit
asset:

```swift
@CloudModel
final class AssetExample {
    @Attribute(.externalStorage)
    var payload: Data
}
```

Uploads use an explicit ``CloudAssetStager`` lease and the
``CloudKitDatabaseClient`` asset overload. A model getter never performs an
implicit download.

## Relationships

`@Relationship` declares a typed relationship with an explicit inverse. Use
`inverseName` when the inverse lives in another declaration, because
cross-model key-path expressions can trigger circular-reference diagnostics in
macro expansion.

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
```

To-many relationships are persisted as canonical edge records, not as an
unbounded array of references on the owner. See <doc:RelationshipsAndMigrations>.

## Schema metadata

Every `@CloudModel` exposes static `schemaMetadata` and a
``CloudModelSchema`` through `cloudModelSchema()`. Schema values are immutable,
`Codable`, `Hashable`, and `Sendable`, and a ``CloudSchema`` is validated before
any CloudKit request is made.

```swift
for property in Project.schemaMetadata {
    print("\(property.name): \(String(describing: property.metadata))")
}
```
