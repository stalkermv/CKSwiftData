import CKSwiftData
import Testing

struct CloudMigrationValidationTests {
    private let modelID: CloudModelIdentifier
    private let title: CloudFieldIdentifier
    private let heading: CloudFieldIdentifier
    private let subtitle: CloudFieldIdentifier
    private let parent: CloudFieldIdentifier

    init() throws {
        modelID = try CloudModelIdentifier("Task")
        title = try CloudFieldIdentifier("title")
        heading = try CloudFieldIdentifier("heading")
        subtitle = try CloudFieldIdentifier("subtitle")
        parent = try CloudFieldIdentifier("parent")
    }

    @Test
    func coordinatorRejectsCompletedCheckpointThatSkipsStages() async throws {
        let plan = try CloudMigrationPlan.build(
            from: schema(version: 1, fields: [attribute(title)]),
            to: schema(version: 2, fields: [
                attribute(title),
                attribute(subtitle, optionality: .optional)
            ])
        )
        #expect(plan.stages.isEmpty == false)
        let store = InMemoryCloudMigrationCheckpointStore()
        try await store.save(CloudMigrationCheckpoint(
            migrationID: plan.id,
            stageIndex: 0,
            completed: true
        ))
        let executor = CountingExecutor()

        await #expect(throws: CloudMigrationError.invalidStageIndex(0)) {
            try await CloudMigrationCoordinator(checkpointStore: store).run(plan, using: executor)
        }
        #expect(await executor.invocations == 0)
    }

    @Test
    func coordinatorReturnsCompletedCheckpointThatCoversEveryStage() async throws {
        let plan = try CloudMigrationPlan.build(
            from: schema(version: 1, fields: [attribute(title)]),
            to: schema(version: 2, fields: [
                attribute(title),
                attribute(subtitle, optionality: .optional)
            ])
        )
        let completed = try CloudMigrationCheckpoint(
            migrationID: plan.id,
            stageIndex: plan.stages.count,
            completed: true
        )
        let store = InMemoryCloudMigrationCheckpointStore()
        try await store.save(completed)
        let executor = CountingExecutor()

        let result = try await CloudMigrationCoordinator(checkpointStore: store).run(plan, using: executor)
        #expect(result == completed)
        #expect(await executor.invocations == 0)
    }

    @Test
    func plannerRejectsRenamingARelationshipIntoAnAttribute() throws {
        let relationship = try CloudFieldSchema.relationship(CloudRelationshipSchema(
            id: parent,
            recordName: parent,
            destination: modelID,
            cardinality: .toOne(required: false)
        ))
        #expect(throws: CloudMigrationError.self) {
            try CloudMigrationPlan.build(
                from: schema(version: 1, fields: [attribute(title), relationship]),
                to: schema(version: 2, fields: [
                    attribute(title),
                    attribute(heading, optionality: .optional, renamedFrom: parent)
                ])
            )
        }
    }

    @Test
    func plannerRejectsRenameThatChangesTheValueKind() throws {
        #expect(throws: CloudMigrationError.self) {
            try CloudMigrationPlan.build(
                from: schema(version: 1, fields: [attribute(title, valueKind: .string)]),
                to: schema(version: 2, fields: [
                    attribute(heading, renamedFrom: title, valueKind: .int64)
                ])
            )
        }
    }

    @Test
    func plannerRejectsTwoFieldsRenamedFromOneSource() throws {
        #expect(throws: CloudMigrationError.self) {
            try CloudMigrationPlan.build(
                from: schema(version: 1, fields: [attribute(title)]),
                to: schema(version: 2, fields: [
                    attribute(heading, renamedFrom: title),
                    attribute(subtitle, renamedFrom: title)
                ])
            )
        }
    }

    @Test
    func plannerRejectsRenameFromAFieldThatIsStillDeclared() throws {
        #expect(throws: CloudMigrationError.self) {
            try CloudMigrationPlan.build(
                from: schema(version: 1, fields: [attribute(title)]),
                to: schema(version: 2, fields: [
                    attribute(title),
                    attribute(heading, renamedFrom: title)
                ])
            )
        }
    }

    @Test
    func plannerAcceptsOneToOneCompatibleRename() throws {
        let plan = try CloudMigrationPlan.build(
            from: schema(version: 1, fields: [attribute(title, valueKind: .string)]),
            to: schema(version: 2, fields: [
                attribute(heading, renamedFrom: title, valueKind: .string)
            ])
        )
        #expect(plan.changes.map(\.compatibility) == [.rename])
    }

    private actor CountingExecutor: CloudMigrationStageExecutor {
        var invocations = 0

        func execute(
            _ stage: CloudMigrationStage,
            checkpoint: CloudMigrationCheckpoint
        ) async throws -> CloudMigrationCheckpoint {
            invocations += 1
            return try checkpoint.advancing(
                stageIndex: checkpoint.stageIndex + 1,
                cursor: nil,
                processedRecords: checkpoint.processedRecords + 1
            )
        }
    }

    private func attribute(
        _ id: CloudFieldIdentifier,
        optionality: CloudFieldOptionality = .required,
        renamedFrom: CloudFieldIdentifier? = nil,
        valueKind: CloudRecordValueKind? = nil
    ) throws -> CloudFieldSchema {
        try .attribute(CloudAttributeSchema(
            id: id,
            recordName: id,
            kind: .scalar,
            optionality: optionality,
            renamedFrom: renamedFrom,
            valueKind: valueKind
        ))
    }

    private func schema(version: Int, fields: [CloudFieldSchema]) throws -> CloudSchema {
        try CloudSchema(version: version, models: [
            CloudModelSchema(id: modelID, recordType: modelID, version: version, fields: fields)
        ])
    }
}
