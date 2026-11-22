# Modeling

Describe fields, relationships, and schema metadata with macros.

## Attributes

Stored properties of a `@CloudModel` class are persisted. Use `@Attribute` to
adjust a field, and `@Transient` to keep a property out of the record.

```swift
@CloudModel(schemaVersion: 1)
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

## Record types

The CloudKit record type of a model is the name of its class. Pass `recordType:`
to use another name. Relationships and the schema use the declared record type.

```swift
@CloudModel(recordType: "Document", schemaVersion: 1)
final class LegacyDocument {
    var title: String = ""
}
```

> Important: Renaming a class changes its record type in CloudKit when you do
> not pass `recordType:`. Set `recordType:` explicitly for models that are
> already in production.

## Relationships

`@Relationship` declares a typed relationship. Name the inverse on one side
with a key path that starts at the destination type. The other side is filled in
when the schema is built, so it needs no arguments.

```swift
@CloudModel
final class Project {
    var name: String = ""
    @Relationship(deleteRule: .cascade, inverse: \TodoItem.project)
    var tasks: [TodoItem] = []
}

@CloudModel
final class TodoItem {
    var title: String = ""
    @Relationship var project: Project?
}
```

Do not put a key path on both sides: the compiler reports a circular reference
while it expands the macros. If you prefer to name both sides, use
`inverseName:` with the property name on each side:

```swift
@Relationship(deleteRule: .cascade, inverseName: "project")
var tasks: [TodoItem] = []
```

The key path must name one property of the destination type, and `CloudSchema`
checks that the inverse exists and points back. A property that two
relationships name as their inverse is rejected as ambiguous.

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
