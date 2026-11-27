import CloudKit

extension CKBackingData {
    /// Updates the inverse record directly instead of calling its public
    /// setter. Direct mutation keeps relationship changes cycle-safe and also
    /// lets cross-declaration inverses use the stable `inverseName` emitted by
    /// the macro when a typed key path is unavailable.
    func updateInverseRelationship<RelatedModel>(
        for relatedModel: RelatedModel,
        relation: Schema.Relationship,
        adding: Bool
    ) where RelatedModel: CloudKitModel {
        guard let inverseName = relation.inverseName,
              let inverseProperty = RelatedModel.schemaMetadata[inverseName],
              let inverseRelation = inverseProperty.metadata as? Schema.Relationship,
              let relatedBacking = relatedModel.persistentBackingData as? CKBackingData<RelatedModel>
        else {
            return
        }

        if inverseRelation.isToOneRelationship {
            updateToOneInverse(
                relatedBacking: relatedBacking,
                property: inverseProperty,
                adding: adding
            )
        } else {
            updateToManyInverse(
                relatedBacking: relatedBacking,
                property: inverseProperty,
                adding: adding
            )
        }
    }
}

private extension CKBackingData {
    func updateToOneInverse<RelatedModel>(
        relatedBacking: CKBackingData<RelatedModel>,
        property: Schema.PropertyMetadata,
        adding: Bool
    ) where RelatedModel: CloudKitModel {
        if adding {
            relatedBacking.record[property.name] = CKRecord.Reference(
                recordID: recordID,
                action: .none
            )
            relatedBacking.relatedBackingData[property.name] = self
        } else if let reference = relatedBacking.record[property.name] as? CKRecord.Reference,
                  reference.recordID == recordID
        {
            relatedBacking.record[property.name] = nil
            relatedBacking.relatedBackingData.removeValue(forKey: property.name)
        }
        relatedBacking.clearCachedRelationship(property.name)
    }

    func updateToManyInverse<RelatedModel>(
        relatedBacking: CKBackingData<RelatedModel>,
        property: Schema.PropertyMetadata,
        adding: Bool
    ) where RelatedModel: CloudKitModel {
        var references = relatedBacking.record[property.name] as? [CKRecord.Reference] ?? []
        var relatedData = relatedBacking.relatedBackingData[property.name] as? [String: Any] ?? [:]
        let reference = CKRecord.Reference(recordID: recordID, action: .none)

        if adding {
            if references.contains(where: { $0.recordID == recordID }) == false {
                references.append(reference)
            }
            relatedData[recordID.recordName] = self
        } else {
            references.removeAll { $0.recordID == recordID }
            relatedData.removeValue(forKey: recordID.recordName)
        }

        relatedBacking.record[property.name] = references.isEmpty ? nil : references
        if relatedData.isEmpty {
            relatedBacking.relatedBackingData.removeValue(forKey: property.name)
        } else {
            relatedBacking.relatedBackingData[property.name] = relatedData
        }
        relatedBacking.clearCachedRelationship(property.name)
    }
}
