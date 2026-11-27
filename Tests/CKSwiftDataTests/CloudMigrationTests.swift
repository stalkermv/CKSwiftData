import CKSwiftData
import Testing

struct CloudMigrationTests {
    @Test
    func migrationPlannerClassifiesAdditionsAndRenames() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let oldTitle = try CloudFieldIdentifier("old_title")
        let note = try CloudFieldIdentifier("note")
        let oldSchema = try schema(
            version: 1,
            modelID: modelID,
            fields: [
                .attribute(CloudAttributeSchema(id: oldTitle, recordName: oldTitle, kind: .scalar))
            ]
        )
        let newSchema = try schema(
            version: 2,
            modelID: modelID,
            fields: [
                .attribute(CloudAttributeSchema(
                    id: title,
                    recordName: title,
                    kind: .scalar,
                    renamedFrom: oldTitle
                )),
                .attribute(CloudAttributeSchema(
                    id: note,
                    recordName: note,
                    kind: .scalar,
                    optionality: .optional
                ))
            ]
        )

        let plan = try CloudMigrationPlan.build(from: oldSchema, to: newSchema)
        #expect(plan.changes.map(\.compatibility) == [.additive, .rename])
        #expect(plan.stages.count == 2)

        let checkpointStore = InMemoryCloudMigrationCheckpointStore()
        let initial = try CloudMigrationCheckpoint(migrationID: plan.id)
        try await checkpointStore.save(initial)
        let resumed = try await checkpointStore.load(migrationID: plan.id)
        #expect(resumed == initial)
        let completed = try initial.advancing(
            stageIndex: plan.stages.count,
            cursor: nil,
            processedRecords: 12,
            completed: true
        )
        try await checkpointStore.save(completed)
        #expect(try await checkpointStore.load(migrationID: plan.id)?.completed == true)
    }

    @Test
    func migrationPlannerRejectsDestructiveFieldRemoval() throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let oldSchema = try schema(
            version: 1,
            modelID: modelID,
            fields: [.attribute(CloudAttributeSchema(id: title, recordName: title, kind: .scalar))]
        )
        let newSchema = try schema(version: 2, modelID: modelID, fields: [])
        do {
            _ = try CloudMigrationPlan.build(from: oldSchema, to: newSchema)
            Issue.record("destructive removal must require an explicit operator stage")
        } catch let error as CloudMigrationError {
            #expect(error == .incompatibleField(
                modelID,
                title,
                reason: "field removal requires a checked-in cleanup stage"
            ))
        }
    }

    @Test
    func migrationPlannerRequiresBackfillForNewRequiredFields() throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let note = try CloudFieldIdentifier("note")
        let oldSchema = try schema(
            version: 1,
            modelID: modelID,
            fields: [.attribute(CloudAttributeSchema(
                id: title,
                recordName: title,
                kind: .scalar
            ))]
        )
        let newSchema = try schema(
            version: 2,
            modelID: modelID,
            fields: [
                .attribute(CloudAttributeSchema(
                    id: title,
                    recordName: title,
                    kind: .scalar
                )),
                .attribute(CloudAttributeSchema(
                    id: note,
                    recordName: note,
                    kind: .scalar,
                    optionality: .required
                ))
            ]
        )

        let plan = try CloudMigrationPlan.build(from: oldSchema, to: newSchema)
        #expect(plan.changes.contains {
            $0.fieldID == note && $0.compatibility == .requiresBackfill
        })
        #expect(plan.stages.contains {
            if case .backfillRequiredField(modelID: modelID, field: .attribute(let field)) = $0 {
                return field.id == note
            }
            return false
        })
    }

    @Test
    func coordinatorPersistsStageProgressAndCompletion() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let oldField = try CloudFieldIdentifier("title")
        let newField = try CloudFieldIdentifier("note")
        let oldSchema = try schema(
            version: 1,
            modelID: modelID,
            fields: [.attribute(CloudAttributeSchema(
                id: oldField,
                recordName: oldField,
                kind: .scalar
            ))]
        )
        let newSchema = try schema(
            version: 2,
            modelID: modelID,
            fields: [
                .attribute(CloudAttributeSchema(
                    id: oldField,
                    recordName: oldField,
                    kind: .scalar
                )),
                .attribute(CloudAttributeSchema(
                    id: newField,
                    recordName: newField,
                    kind: .scalar,
                    optionality: .optional
                ))
            ]
        )
        let plan = try CloudMigrationPlan.build(from: oldSchema, to: newSchema)
        let store = InMemoryCloudMigrationCheckpointStore()
        let coordinator = CloudMigrationCoordinator(checkpointStore: store)
        let executor = TestMigrationExecutor()

        let checkpoint = try await coordinator.run(plan, using: executor)
        #expect(checkpoint.completed)
        #expect(checkpoint.stageIndex == plan.stages.count)
        #expect(checkpoint.processedRecords == plan.stages.count)
        #expect(await executor.invocations == plan.stages.count)
        #expect(try await store.load(migrationID: plan.id) == checkpoint)
    }

    @Test
    func coordinatorRejectsConcurrentRunsForSamePlan() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let note = try CloudFieldIdentifier("note")
        let oldSchema = try schema(
            version: 1,
            modelID: modelID,
            fields: [.attribute(CloudAttributeSchema(
                id: title,
                recordName: title,
                kind: .scalar
            ))]
        )
        let newSchema = try schema(
            version: 2,
            modelID: modelID,
            fields: [
                .attribute(CloudAttributeSchema(
                    id: title,
                    recordName: title,
                    kind: .scalar
                )),
                .attribute(CloudAttributeSchema(
                    id: note,
                    recordName: note,
                    kind: .scalar,
                    optionality: .optional
                ))
            ]
        )
        let plan = try CloudMigrationPlan.build(from: oldSchema, to: newSchema)
        let coordinator = CloudMigrationCoordinator(
            checkpointStore: InMemoryCloudMigrationCheckpointStore()
        )
        let executor = GatedMigrationExecutor()
        let firstRun = Task { try await coordinator.run(plan, using: executor) }
        await executor.waitUntilStarted()

        do {
            _ = try await coordinator.run(plan, using: executor)
            Issue.record("a migration plan must not execute concurrently")
        } catch let error as CloudMigrationError {
            #expect(error == .migrationAlreadyRunning(plan.id))
        }

        await executor.release()
        let checkpoint = try await firstRun.value
        #expect(checkpoint.completed)
    }

    private actor TestMigrationExecutor: CloudMigrationStageExecutor {
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

    private actor GatedMigrationExecutor: CloudMigrationStageExecutor {
        private let started: AsyncStream<Void>
        private let startedContinuation: AsyncStream<Void>.Continuation
        private let releaseStream: AsyncStream<Void>
        private let releaseContinuation: AsyncStream<Void>.Continuation

        init() {
            let startedPair = AsyncStream<Void>.makeStream()
            let releasePair = AsyncStream<Void>.makeStream()
            started = startedPair.stream
            startedContinuation = startedPair.continuation
            releaseStream = releasePair.stream
            releaseContinuation = releasePair.continuation
        }

        func execute(
            _ stage: CloudMigrationStage,
            checkpoint: CloudMigrationCheckpoint
        ) async throws -> CloudMigrationCheckpoint {
            startedContinuation.yield(())
            startedContinuation.finish()
            var iterator = releaseStream.makeAsyncIterator()
            _ = await iterator.next()
            return try checkpoint.advancing(
                stageIndex: checkpoint.stageIndex + 1,
                cursor: nil,
                processedRecords: checkpoint.processedRecords + 1
            )
        }

        func waitUntilStarted() async {
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()
        }

        func release() {
            releaseContinuation.yield(())
        }
    }

    private func schema(
        version: Int,
        modelID: CloudModelIdentifier,
        fields: [CloudFieldSchema]
    ) throws -> CloudSchema {
        try CloudSchema(version: version, models: [
            CloudModelSchema(id: modelID, recordType: modelID, version: version, fields: fields)
        ])
    }
}
