import CKSwiftData

@CloudModel
final class TypedInverseProject {
    var name: String = ""
    @Relationship(deleteRule: .cascade, inverse: \TypedInverseTask.project)
    var tasks: [TypedInverseTask] = []
}

@CloudModel
final class TypedInverseFolder {
    var title: String = ""
    @Relationship var parent: TypedInverseFolder?
    @Relationship(deleteRule: .cascade, inverse: \TypedInverseFolder.parent)
    var children: [TypedInverseFolder] = []
}

@CloudModel(recordType: "StableOwner", schemaVersion: 1)
final class TypedInverseStableOwner {
    var name: String = ""
    @Relationship(deleteRule: .cascade, inverse: \TypedInverseStableItem.owner)
    var items: [TypedInverseStableItem] = []
}
