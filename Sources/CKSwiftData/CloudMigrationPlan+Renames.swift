import Foundation

extension CloudMigrationPlan {
    /// Checks that renaming `source` into `destination` keeps every stored
    /// value meaningful. A rename copies values field to field, so it is only
    /// accepted between attributes with the same storage, from a source that
    /// the new schema no longer declares, and with exactly one destination
    /// per source.
    static func validateRename(
        of source: CloudFieldSchema,
        to destination: CloudAttributeSchema,
        in model: CloudModelSchema,
        retainedFields: [CloudFieldIdentifier: CloudFieldSchema],
        claimedSources: inout Set<CloudFieldIdentifier>
    ) throws {
        guard case let .attribute(sourceAttribute) = source else {
            throw CloudMigrationError.incompatibleField(
                model.id,
                destination.id,
                reason: "a relationship cannot be renamed into an attribute"
            )
        }
        // A missing value kind is unknown, not different: manifests written
        // before value kinds existed must still be able to rename.
        let valueKindsAgree = sourceAttribute.valueKind == nil ||
            destination.valueKind == nil ||
            sourceAttribute.valueKind == destination.valueKind
        guard sourceAttribute.kind == destination.kind,
              sourceAttribute.optionality == destination.optionality,
              sourceAttribute.encrypted == destination.encrypted,
              sourceAttribute.externalStorage == destination.externalStorage,
              valueKindsAgree
        else {
            throw CloudMigrationError.incompatibleField(
                model.id,
                destination.id,
                reason: "a rename cannot change the attribute kind or storage options"
            )
        }
        guard retainedFields[sourceAttribute.id] == nil else {
            throw CloudMigrationError.incompatibleField(
                model.id,
                destination.id,
                reason: "the renamed field \(sourceAttribute.id.rawValue) is still declared"
            )
        }
        guard claimedSources.insert(sourceAttribute.id).inserted else {
            throw CloudMigrationError.incompatibleField(
                model.id,
                destination.id,
                reason: "another field is already renamed from \(sourceAttribute.id.rawValue)"
            )
        }
    }
}
