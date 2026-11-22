import CKSwiftData

@CloudModel
final class TypedInverseTask {
    var title: String = ""
    @Relationship var project: TypedInverseProject?
}

@CloudModel
final class TypedInverseNote {
    var text: String = ""
    @Relationship(inverse: \TypedInverseOwner.notes) var owner: TypedInverseOwner?
}

@CloudModel
final class TypedInverseOwner {
    var name: String = ""
    @Relationship var notes: [TypedInverseNote] = []
}

@CloudModel(recordType: "StableItem", schemaVersion: 1)
final class TypedInverseStableItem {
    var title: String = ""
    @Relationship var owner: TypedInverseStableOwner?
}
