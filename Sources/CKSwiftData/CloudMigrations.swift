import Foundation

public enum CloudMigrationError: Error, Codable, Equatable, Hashable, Sendable {
    case versionMustIncrease(from: Int, to: Int)
    case incompatibleModel(CloudModelIdentifier, reason: String)
    case incompatibleField(CloudModelIdentifier, CloudFieldIdentifier, reason: String)
    case invalidStageIndex(Int)
    case invalidStageProgress(stageIndex: Int, nextStageIndex: Int)
    case invalidProcessedCount(Int)
    case checkpointMigrationMismatch(UUID)
    case migrationAlreadyRunning(UUID)
}

public enum CloudMigrationCompatibility: String, Codable, Hashable, Sendable {
    case additive
    case rename
    case requiresBackfill
    case incompatible
}

public struct CloudMigrationChange: Codable, Hashable, Sendable {
    public let modelID: CloudModelIdentifier
    public let fieldID: CloudFieldIdentifier?
    public let compatibility: CloudMigrationCompatibility
    public let summary: String

    public init(
        modelID: CloudModelIdentifier,
        fieldID: CloudFieldIdentifier? = nil,
        compatibility: CloudMigrationCompatibility,
        summary: String
    ) {
        self.modelID = modelID
        self.fieldID = fieldID
        self.compatibility = compatibility
        self.summary = summary
    }
}

public enum CloudMigrationStage: Codable, Hashable, Sendable {
    case addField(modelID: CloudModelIdentifier, field: CloudFieldSchema)
    case renameField(
        modelID: CloudModelIdentifier,
        from: CloudFieldIdentifier,
        to: CloudFieldSchema
    )
    case backfillRequiredField(modelID: CloudModelIdentifier, field: CloudFieldSchema)
    case verify(modelID: CloudModelIdentifier)
}

public struct CloudMigrationPlan: Codable, Hashable, Sendable {
    public let id: UUID
    public let fromSchema: CloudSchema
    public let toSchema: CloudSchema
    public let changes: [CloudMigrationChange]
    public let stages: [CloudMigrationStage]

    public init(
        id: UUID = UUID(),
        fromSchema: CloudSchema,
        toSchema: CloudSchema,
        changes: [CloudMigrationChange],
        stages: [CloudMigrationStage]
    ) throws {
        guard toSchema.version > fromSchema.version else {
            throw CloudMigrationError.versionMustIncrease(
                from: fromSchema.version,
                to: toSchema.version
            )
        }
        self.id = id
        self.fromSchema = fromSchema
        self.toSchema = toSchema
        self.changes = changes
        self.stages = stages
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case fromSchema
        case toSchema
        case changes
        case stages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            fromSchema: container.decode(CloudSchema.self, forKey: .fromSchema),
            toSchema: container.decode(CloudSchema.self, forKey: .toSchema),
            changes: container.decode([CloudMigrationChange].self, forKey: .changes),
            stages: container.decode([CloudMigrationStage].self, forKey: .stages)
        )
    }

    /// Classifies a schema transition and emits only explicit, executable
    /// declarative stages. Destructive or type-changing edits are rejected.
    public static func build(
        from oldSchema: CloudSchema,
        to newSchema: CloudSchema,
        id: UUID = UUID()
    ) throws -> CloudMigrationPlan {
        guard newSchema.version > oldSchema.version else {
            throw CloudMigrationError.versionMustIncrease(
                from: oldSchema.version,
                to: newSchema.version
            )
        }
        var changes = [CloudMigrationChange]()
        var stages = [CloudMigrationStage]()

        let oldModels = Dictionary(uniqueKeysWithValues: oldSchema.models.map { ($0.id, $0) })
        let newModels = Dictionary(uniqueKeysWithValues: newSchema.models.map { ($0.id, $0) })

        for oldModel in oldSchema.models where newModels[oldModel.id] == nil {
            throw CloudMigrationError.incompatibleModel(
                oldModel.id,
                reason: "model removal requires an operator-managed copy and cleanup"
            )
        }

        for newModel in newSchema.models {
            guard let oldModel = oldModels[newModel.id] else {
                throw CloudMigrationError.incompatibleModel(
                    newModel.id,
                    reason: "new record types require an explicit deployment stage"
                )
            }
            if oldModel.recordType != newModel.recordType {
                throw CloudMigrationError.incompatibleModel(
                    newModel.id,
                    reason: "record type changes require an explicit copy stage"
                )
            }

            let oldFields = Dictionary(uniqueKeysWithValues: oldModel.fields.map { ($0.id, $0) })
            let newFields = Dictionary(uniqueKeysWithValues: newModel.fields.map { ($0.id, $0) })
            for oldField in oldModel.fields where newFields[oldField.id] == nil {
                let wasRenamed = newModel.fields.contains { field in
                    switch field {
                    case let .attribute(attribute):
                        attribute.renamedFrom == oldField.id
                    case .relationship:
                        false
                    }
                }
                guard wasRenamed else {
                    throw CloudMigrationError.incompatibleField(
                        newModel.id,
                        oldField.id,
                        reason: "field removal requires a checked-in cleanup stage"
                    )
                }
            }

            for newField in newModel.fields {
                guard let oldField = oldFields[newField.id] else {
                    if case let .attribute(newAttribute) = newField,
                       let renamedFrom = newAttribute.renamedFrom,
                       oldFields[renamedFrom] != nil
                    {
                        changes.append(CloudMigrationChange(
                            modelID: newModel.id,
                            fieldID: newField.id,
                            compatibility: .rename,
                            summary: "rename \(renamedFrom.rawValue) to \(newField.id.rawValue)"
                        ))
                        stages.append(.renameField(
                            modelID: newModel.id,
                            from: renamedFrom,
                            to: newField
                        ))
                        continue
                    }
                    let compatibility: CloudMigrationCompatibility
                    let stage: CloudMigrationStage
                    if case let .attribute(attribute) = newField,
                       attribute.optionality == .required
                    {
                        compatibility = .requiresBackfill
                        stage = .backfillRequiredField(
                            modelID: newModel.id,
                            field: newField
                        )
                    } else {
                        compatibility = .additive
                        stage = .addField(modelID: newModel.id, field: newField)
                    }
                    changes.append(CloudMigrationChange(
                        modelID: newModel.id,
                        fieldID: newField.id,
                        compatibility: compatibility,
                        summary: compatibility == .requiresBackfill
                            ? "add and backfill \(newField.id.rawValue)"
                            : "add \(newField.id.rawValue)"
                    ))
                    stages.append(stage)
                    continue
                }
                if oldField == newField { continue }
                switch (oldField, newField) {
                case let (.attribute(oldAttribute), .attribute(newAttribute)):
                    guard oldAttribute.kind == newAttribute.kind,
                          oldAttribute.optionality == newAttribute.optionality,
                          oldAttribute.encrypted == newAttribute.encrypted,
                          oldAttribute.externalStorage == newAttribute.externalStorage
                    else {
                        throw CloudMigrationError.incompatibleField(
                            newModel.id,
                            newField.id,
                            reason: "attribute kind or storage options changed"
                        )
                    }
                    if newAttribute.renamedFrom == oldAttribute.id ||
                        newAttribute.recordName != oldAttribute.recordName
                    {
                        changes.append(CloudMigrationChange(
                            modelID: newModel.id,
                            fieldID: newField.id,
                            compatibility: .rename,
                            summary: "rename \(oldAttribute.recordName.rawValue) to \(newAttribute.recordName.rawValue)"
                        ))
                        stages.append(.renameField(
                            modelID: newModel.id,
                            from: oldAttribute.id,
                            to: newField
                        ))
                    } else {
                        throw CloudMigrationError.incompatibleField(
                            newModel.id,
                            newField.id,
                            reason: "attribute metadata changed without a rename identity"
                        )
                    }
                case let (.relationship(oldRelationship), .relationship(newRelationship)):
                    guard oldRelationship.destination == newRelationship.destination,
                          oldRelationship.cardinality == newRelationship.cardinality,
                          oldRelationship.deleteRule == newRelationship.deleteRule
                    else {
                        throw CloudMigrationError.incompatibleField(
                            newModel.id,
                            newField.id,
                            reason: "relationship destination/cardinality/delete rule changed"
                        )
                    }
                    changes.append(CloudMigrationChange(
                        modelID: newModel.id,
                        fieldID: newField.id,
                        compatibility: .requiresBackfill,
                        summary: "relationship inverse or record name changed"
                    ))
                    stages.append(.verify(modelID: newModel.id))
                default:
                    throw CloudMigrationError.incompatibleField(
                        newModel.id,
                        newField.id,
                        reason: "attribute/relationship kind changed"
                    )
                }
            }
        }

        return try CloudMigrationPlan(
            id: id,
            fromSchema: oldSchema,
            toSchema: newSchema,
            changes: changes,
            stages: stages
        )
    }
}

public protocol CloudMigrationCheckpointStore: Sendable {
    func load(migrationID: UUID) async throws -> CloudMigrationCheckpoint?
    func save(_ checkpoint: CloudMigrationCheckpoint) async throws
}

/// Performs one resumable migration stage. An executor may return the same
/// stage index with a new cursor/progress for page-by-page backfills, or the
/// next stage index after completing the current stage.
public protocol CloudMigrationStageExecutor: Sendable {
    func execute(
        _ stage: CloudMigrationStage,
        checkpoint: CloudMigrationCheckpoint
    ) async throws -> CloudMigrationCheckpoint
}
