import CKSwiftData
import Foundation
import Testing

private actor PausingRecordClient: CloudDatabaseClient {
    private let base: any CloudDatabaseClient
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false
    private var shouldPause = true

    init(base: any CloudDatabaseClient) {
        self.base = base
    }

    func waitUntilModifyBegins() async {
        while entered == false {
            await Task.yield()
        }
    }

    func releaseModify() {
        if let releaseContinuation {
            releaseContinuation.resume()
            self.releaseContinuation = nil
        } else {
            releaseRequested = true
        }
    }

    func fetch(_ request: CloudRecordFetchRequest) async throws -> CloudRecordPage {
        try await base.fetch(request)
    }

    func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        atomic: Bool
    ) async throws -> CloudModifyResult {
        entered = true
        if shouldPause {
            shouldPause = false
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                if releaseRequested {
                    releaseRequested = false
                    releaseContinuation = nil
                    continuation.resume()
                }
            }
        }
        return try await base.modify(
            saving: mutations,
            deleting: recordIDs,
            atomic: atomic
        )
    }
}

@MainActor
struct CloudRecordContextTests {
    @Test
    func fetchTracksCleanValuesAndSavePromotesStagedValues() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("private")
        let id = try CloudRecordIdentifier(recordName: "task-1", zone: zone)
        let schema = try makeSchema(modelID: modelID, title: title)
        let initial = try CloudRecordSnapshot(
            id: id,
            modelID: modelID,
            changeTag: "c1",
            fields: [title: .string("old")]
        )
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [initial])
        let configuration = try makeConfiguration()
        let context = CloudRecordContext(
            schema: schema,
            configuration: configuration,
            client: client
        )

        _ = try await context.fetch(CloudRecordFetchRequest(modelID: modelID))
        #expect(context.state(for: id) == .clean)
        #expect(context.snapshot(for: id)?.fields[title] == .string("old"))

        let mutation = try CloudRecordMutation(
            id: id,
            modelID: modelID,
            values: [title: .string("new")],
            policy: .update(expectedChangeTag: "c1")
        )
        try context.stage(mutation)
        #expect(context.state(for: id) == .dirty)
        #expect(context.hasChanges)

        let result = try await context.save()
        #expect(result.failures.isEmpty)
        #expect(context.state(for: id) == .clean)
        #expect(context.snapshot(for: id)?.fields[title] == .string("new"))
        #expect(context.lastFailure(for: id) == nil)
    }

    @Test
    func saveReturnsInsertedRecordsInCanonicalOrder() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("private")
        let schema = try makeSchema(modelID: modelID, title: title)
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        let context = try CloudRecordContext(
            schema: schema,
            configuration: makeConfiguration(),
            client: client
        )
        let laterID = try CloudRecordIdentifier(recordName: "zzz", zone: zone)
        let earlierID = try CloudRecordIdentifier(recordName: "aaa", zone: zone)

        try context.insert(CloudRecordSnapshot(
            id: laterID,
            modelID: modelID,
            fields: [title: .string("later")]
        ))
        try context.insert(CloudRecordSnapshot(
            id: earlierID,
            modelID: modelID,
            fields: [title: .string("earlier")]
        ))

        let result = try await context.save()

        #expect(result.saved.map(\.id) == [earlierID, laterID])
    }

    @Test
    func lowLevelDiscardRefreshRejectsProjectedRequest() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("private")
        let id = try CloudRecordIdentifier(recordName: "task-projected-discard", zone: zone)
        let schema = try makeSchema(modelID: modelID, title: title)
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: id,
                modelID: modelID,
                changeTag: "c1",
                fields: [title: .string("server")]
            )
        ])
        let context = try CloudRecordContext(
            schema: schema,
            configuration: makeConfiguration(),
            client: client
        )

        do {
            _ = try await context.refresh(
                CloudRecordFetchRequest(
                    modelID: modelID,
                    desiredFields: [title]
                ),
                discardLocalChanges: true
            )
            Issue.record("A low-level projected discard refresh must fail closed")
        } catch let error as CloudContextError {
            #expect(error == .partialRefreshRequiresFullFetch(modelID))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func ordinaryRefreshMatchesFetchMergeSemantics() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("private")
        let id = try CloudRecordIdentifier(recordName: "task-ordinary-refresh", zone: zone)
        let cleanID = try CloudRecordIdentifier(recordName: "task-ordinary-refresh-clean", zone: zone)
        let initial = try CloudRecordSnapshot(
            id: id,
            modelID: modelID,
            changeTag: "c1",
            fields: [title: .string("server")]
        )
        let cleanInitial = try CloudRecordSnapshot(
            id: cleanID,
            modelID: modelID,
            changeTag: "c1",
            fields: [title: .string("server-clean")]
        )
        let schema = try makeSchema(modelID: modelID, title: title)
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [initial, cleanInitial])
        let fetchContext = try CloudRecordContext(
            schema: schema,
            configuration: makeConfiguration(),
            client: client
        )
        let refreshContext = try CloudRecordContext(
            schema: schema,
            configuration: makeConfiguration(),
            client: client
        )
        let request = try CloudRecordFetchRequest(modelID: modelID)

        _ = try await fetchContext.fetch(request)
        _ = try await refreshContext.fetch(request)
        let localMutation = try CloudRecordMutation(
            id: id,
            modelID: modelID,
            values: [title: .string("local")],
            policy: .update(expectedChangeTag: "c1")
        )
        try fetchContext.stage(localMutation)
        try refreshContext.stage(localMutation)
        _ = try await client.modify(
            saving: [CloudRecordMutation(
                id: id,
                modelID: modelID,
                values: [title: .string("remote")],
                policy: .update(expectedChangeTag: "c1")
            ), CloudRecordMutation(
                id: cleanID,
                modelID: modelID,
                values: [title: .string("remote-clean")],
                policy: .update(expectedChangeTag: "c1")
            )],
            deleting: [],
            atomic: true
        )

        let fetchedPage = try await fetchContext.fetch(request)
        let refreshedPage = try await refreshContext.refresh(
            request,
            discardLocalChanges: false
        )

        #expect(fetchedPage == refreshedPage)
        #expect(fetchContext.snapshot(for: id) == refreshContext.snapshot(for: id))
        #expect(fetchContext.baseline(for: id) == refreshContext.baseline(for: id))
        #expect(fetchContext.state(for: id) == refreshContext.state(for: id))
        #expect(fetchContext.snapshot(for: cleanID)?.fields[title] == .string("remote-clean"))
        #expect(refreshContext.snapshot(for: cleanID)?.fields[title] == .string("remote-clean"))
        #expect(fetchContext.baseline(for: cleanID) == refreshContext.baseline(for: cleanID))
        #expect(fetchContext.state(for: cleanID) == refreshContext.state(for: cleanID))
    }

    @Test
    func fetchDoesNotOverwriteLocalChangesAndRollbackRestoresBaseline() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("private")
        let id = try CloudRecordIdentifier(recordName: "task-1", zone: zone)
        let schema = try makeSchema(modelID: modelID, title: title)
        let initial = try CloudRecordSnapshot(
            id: id,
            modelID: modelID,
            changeTag: "c1",
            fields: [title: .string("server")]
        )
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [initial])
        let context = try CloudRecordContext(
            schema: schema,
            configuration: makeConfiguration(),
            client: client
        )
        _ = try await context.fetch(CloudRecordFetchRequest(modelID: modelID))

        try context.stage(
            CloudRecordMutation(
                id: id,
                modelID: modelID,
                values: [title: .string("local")],
                policy: .update(expectedChangeTag: "c1")
            )
        )
        _ = try await context.fetch(CloudRecordFetchRequest(modelID: modelID))
        #expect(context.snapshot(for: id)?.fields[title] == .string("local"))
        #expect(context.state(for: id) == .dirty)

        context.discardChanges(for: id)
        #expect(context.snapshot(for: id)?.fields[title] == .string("server"))
        #expect(context.state(for: id) == .clean)
    }

    @Test
    func fullFetchKeepsOptimisticConflictForDirtyFullBaseline() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("private")
        let id = try CloudRecordIdentifier(recordName: "task-full-conflict", zone: zone)
        let schema = try makeSchema(modelID: modelID, title: title)
        let initial = try CloudRecordSnapshot(
            id: id,
            modelID: modelID,
            changeTag: "c1",
            fields: [title: .string("server")]
        )
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [initial])
        let context = try CloudRecordContext(
            schema: schema,
            configuration: makeConfiguration(),
            client: client
        )

        _ = try await context.fetch(CloudRecordFetchRequest(modelID: modelID))
        try context.stage(
            CloudRecordMutation(
                id: id,
                modelID: modelID,
                values: [title: .string("local")],
                policy: .update(expectedChangeTag: "c1")
            )
        )
        _ = try await client.modify(
            saving: [CloudRecordMutation(
                id: id,
                modelID: modelID,
                values: [title: .string("remote")],
                policy: .update(expectedChangeTag: "c1")
            )],
            deleting: [],
            atomic: true
        )

        _ = try await context.fetch(CloudRecordFetchRequest(modelID: modelID))
        do {
            _ = try await context.save()
            Issue.record("A full fetch must not rebase an existing full-baseline mutation")
        } catch let error as CloudModelError {
            #expect(error == .conflict(
                id,
                expectedChangeTag: "c1",
                actualChangeTag: "c2"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(context.state(for: id) == .dirty)
    }

    @Test
    func discardRefreshReattachesRemoteAfterInsertedIDCollision() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("private")
        let id = try CloudRecordIdentifier(recordName: "task-collision", zone: zone)
        let schema = try makeSchema(modelID: modelID, title: title)
        let remote = try CloudRecordSnapshot(
            id: id,
            modelID: modelID,
            changeTag: "c1",
            fields: [title: .string("remote")]
        )
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [remote])
        let context = try CloudRecordContext(
            schema: schema,
            configuration: makeConfiguration(),
            client: client
        )
        try context.insert(
            CloudRecordSnapshot(
                id: id,
                modelID: modelID,
                fields: [title: .string("local insert")]
            )
        )

        let page = try await context.refresh(
            CloudRecordFetchRequest(modelID: modelID),
            discardLocalChanges: true
        )
        #expect(page.snapshots.first?.fields[title] == .string("remote"))
        #expect(context.state(for: id) == .clean)
        #expect(context.snapshot(for: id)?.fields[title] == .string("remote"))
    }

    @Test
    func partialFetchMergesKnownFieldsAndKeepsLowLevelMutationScoped() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let note = try CloudFieldIdentifier("note")
        let zone = try CloudZoneIdentifier("private")
        let id = try CloudRecordIdentifier(recordName: "task-1", zone: zone)
        let schema = try CloudSchema(models: [
            CloudModelSchema(
                id: modelID,
                recordType: modelID,
                fields: [
                    .attribute(CloudAttributeSchema(
                        id: title,
                        recordName: title,
                        kind: .scalar
                    )),
                    .attribute(CloudAttributeSchema(
                        id: note,
                        recordName: note,
                        kind: .scalar
                    ))
                ]
            )
        ])
        let initial = try CloudRecordSnapshot(
            id: id,
            modelID: modelID,
            changeTag: "c1",
            fields: [
                title: .string("old title"),
                note: .string("old note")
            ]
        )
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [initial])
        let context = try CloudRecordContext(
            schema: schema,
            configuration: makeConfiguration(),
            client: client
        )

        _ = try await context.fetch(CloudRecordFetchRequest(modelID: modelID))
        _ = try await client.modify(
            saving: [CloudRecordMutation(
                id: id,
                modelID: modelID,
                values: [note: .string("remote note")],
                policy: .update(expectedChangeTag: "c1")
            )],
            deleting: [],
            atomic: true
        )

        _ = try await context.fetch(
            CloudRecordFetchRequest(modelID: modelID, desiredFields: [title])
        )
        let projected = try #require(context.snapshot(for: id))
        let baseline = try #require(context.baseline(for: id))
        #expect(projected.fields[title] == .string("old title"))
        #expect(projected.fields[note] == .string("old note"))
        #expect(projected.changeTag == "c2")
        #expect(projected.isPartial)
        #expect(baseline.fields[note] == .string("old note"))
        #expect(baseline.isPartial)

        // A low-level partial mutation is safe: only its explicit field is
        // sent, so the concurrently changed remote note is preserved.
        try context.stage(
            CloudRecordMutation(
                id: id,
                modelID: modelID,
                values: [title: .string("new title")],
                policy: .update(expectedChangeTag: "c2")
            )
        )
        let result = try await context.save()
        #expect(result.failures.isEmpty)
        let full = try await client.fetch(CloudRecordFetchRequest(modelID: modelID))
        #expect(full.snapshots.first?.fields[title] == .string("new title"))
        #expect(full.snapshots.first?.fields[note] == .string("remote note"))
    }

    @Test
    func partialSaveKeepsFailedRecordsDirtyForAnExplicitRetry() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("private")
        let existingID = try CloudRecordIdentifier(recordName: "task-1", zone: zone)
        let missingID = try CloudRecordIdentifier(recordName: "missing", zone: zone)
        let schema = try makeSchema(modelID: modelID, title: title)
        let initial = try CloudRecordSnapshot(
            id: existingID,
            modelID: modelID,
            changeTag: "c1",
            fields: [title: .string("old")]
        )
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [initial])
        let context = try CloudRecordContext(
            schema: schema,
            configuration: makeConfiguration(),
            client: client
        )
        _ = try await context.fetch(CloudRecordFetchRequest(modelID: modelID))

        try context.stage(
            CloudRecordMutation(
                id: existingID,
                modelID: modelID,
                values: [title: .string("new")],
                policy: .update(expectedChangeTag: "wrong")
            )
        )
        try context.insert(
            CloudRecordSnapshot(
                id: missingID,
                modelID: modelID,
                fields: [title: .string("inserted")]
            )
        )

        let result = try await context.save(atomic: false)
        #expect(result.saved.map(\.id) == [missingID])
        #expect(result.failures.count == 1)
        #expect(context.state(for: existingID) == .dirty)
        #expect(context.lastFailure(for: existingID) != nil)
        #expect(context.state(for: missingID) == .clean)
    }

    @Test
    func upsertRejectsMissingRequiredFieldsBeforeCreatingARecord() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("private")
        let id = try CloudRecordIdentifier(recordName: "task-upsert", zone: zone)
        let context = try CloudRecordContext(
            schema: makeSchema(modelID: modelID, title: title),
            configuration: makeConfiguration(),
            client: CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        )

        do {
            _ = try await context.store.modify(
                saving: [CloudRecordMutation(
                    id: id,
                    modelID: modelID,
                    policy: .upsert
                )],
                deleting: []
            )
            Issue.record("An upsert must not create a record without required fields")
        } catch let error as CloudModelError {
            #expect(error == .invalidRequest("required field title is missing for upsert"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func lowLevelEditDuringSaveRebasesThePendingWritePolicy() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("private")
        let id = try CloudRecordIdentifier(recordName: "task-rebase", zone: zone)
        let schema = try makeSchema(modelID: modelID, title: title)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        let client = PausingRecordClient(base: base)
        let context = try CloudRecordContext(
            schema: schema,
            configuration: makeConfiguration(),
            client: client
        )
        try context.insert(CloudRecordSnapshot(
            id: id,
            modelID: modelID,
            fields: [title: .string("before")]
        ))

        let firstSave = Task { try await context.save() }
        await client.waitUntilModifyBegins()
        try context.stage(CloudRecordMutation(
            id: id,
            modelID: modelID,
            values: [title: .string("after")],
            policy: .insert
        ))
        await client.releaseModify()
        let firstResult = try await firstSave.value
        #expect(firstResult.saved.first?.fields[title] == .string("before"))

        let secondResult = try await context.save()
        #expect(secondResult.failures.isEmpty)
        #expect(secondResult.saved.first?.fields[title] == .string("after"))
        #expect(context.state(for: id) == .clean)
    }

    @Test
    func conflictExposesServerAndSupportsExplicitClientResolution() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("private")
        let id = try CloudRecordIdentifier(recordName: "task-1", zone: zone)
        let schema = try makeSchema(modelID: modelID, title: title)
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: id,
                modelID: modelID,
                changeTag: "c1",
                fields: [title: .string("server")]
            )
        ])
        let context = try CloudRecordContext(
            schema: schema,
            configuration: makeConfiguration(),
            client: client
        )
        _ = try await context.fetch(CloudRecordFetchRequest(modelID: modelID))
        try context.stage(
            CloudRecordMutation(
                id: id,
                modelID: modelID,
                values: [title: .string("client")],
                policy: .update(expectedChangeTag: "stale")
            )
        )
        let result = try await context.save(atomic: false)
        #expect(result.failures.count == 1)
        #expect(context.conflict(for: id)?.server?.fields[title] == .string("server"))

        try context.resolveConflict(for: id, using: .useClient)
        let retry = try await context.save()
        #expect(retry.saved.first?.fields[title] == .string("client"))
        #expect(context.conflict(for: id) == nil)
        #expect(context.state(for: id) == .clean)
    }

    @Test
    func storeRejectsMutationsOutsideConfiguredZone() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let schema = try makeSchema(modelID: modelID, title: title)
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        let context = try CloudRecordContext(
            schema: schema,
            configuration: makeConfiguration(),
            client: client
        )
        let foreignID = try CloudRecordIdentifier(
            recordName: "task-foreign",
            zone: CloudZoneIdentifier("other")
        )
        do {
            _ = try await context.store.modify(
                saving: [CloudRecordMutation(
                    id: foreignID,
                    modelID: modelID,
                    values: [title: .string("blocked")]
                )],
                deleting: []
            )
            Issue.record("a mutation outside the configured zone must be rejected")
        } catch let error as CloudContextError {
            #expect(try error == .invalidZone(
                expected: CloudZoneIdentifier("private"),
                actual: CloudZoneIdentifier("other")
            ))
        }
    }

    private func makeSchema(
        modelID: CloudModelIdentifier,
        title: CloudFieldIdentifier
    ) throws -> CloudSchema {
        let attribute = try CloudAttributeSchema(
            id: title,
            recordName: title,
            kind: .scalar,
            optionality: .required
        )
        let model = try CloudModelSchema(
            id: modelID,
            recordType: modelID,
            fields: [.attribute(attribute)]
        )
        return try CloudSchema(models: [model])
    }

    private func makeConfiguration() throws -> CloudStoreConfiguration {
        try CloudStoreConfiguration(
            containerIdentifier: CloudContainerIdentifier("iCloud.example.Tests"),
            location: .privateDatabase(.custom(CloudZoneIdentifier("private")))
        )
    }
}
