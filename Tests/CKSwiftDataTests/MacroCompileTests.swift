import CKSwiftData
import Testing

private actor PausingCloudClient: CloudDatabaseClient {
    private let base: any CloudDatabaseClient
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(base: any CloudDatabaseClient) {
        self.base = base
    }

    func waitUntilModifyBegins() async {
        while entered == false {
            await Task.yield()
        }
    }

    func releaseModify() {
        releaseContinuation?.resume()
        releaseContinuation = nil
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
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return try await base.modify(
            saving: mutations,
            deleting: recordIDs,
            atomic: atomic
        )
    }
}

private actor PausingFetchCloudClient: CloudDatabaseClient {
    private let base: any CloudDatabaseClient
    private var entered = false
    private var fetchCount = 0
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(base: any CloudDatabaseClient) {
        self.base = base
    }

    func waitUntilFetchBegins() async {
        guard entered == false else { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func releaseFetch() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func fetch(_ request: CloudRecordFetchRequest) async throws -> CloudRecordPage {
        fetchCount += 1
        guard fetchCount > 1 else {
            return try await base.fetch(request)
        }
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return try await base.fetch(request)
    }

    func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        atomic: Bool
    ) async throws -> CloudModifyResult {
        try await base.modify(
            saving: mutations,
            deleting: recordIDs,
            atomic: atomic
        )
    }
}

private actor PausingStaleFetchCloudClient: CloudDatabaseClient {
    private let base: any CloudDatabaseClient
    private var fetchCount = 0
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(base: any CloudDatabaseClient) {
        self.base = base
    }

    func waitUntilPageCaptured() async {
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func releaseFetch() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func fetch(_ request: CloudRecordFetchRequest) async throws -> CloudRecordPage {
        fetchCount += 1
        let page = try await base.fetch(request)
        guard fetchCount == 2 else { return page }
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return page
    }

    func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        atomic: Bool
    ) async throws -> CloudModifyResult {
        try await base.modify(
            saving: mutations,
            deleting: recordIDs,
            atomic: atomic
        )
    }
}

private actor OutOfOrderFetchCloudClient: CloudDatabaseClient {
    private let base: any CloudDatabaseClient
    private let delayedFailure: Bool
    private var fetchCount = 0
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(base: any CloudDatabaseClient, delayedFailure: Bool = false) {
        self.base = base
        self.delayedFailure = delayedFailure
    }

    func waitUntilDelayedFetchBegins() async {
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func releaseDelayedFetch() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func fetch(_ request: CloudRecordFetchRequest) async throws -> CloudRecordPage {
        fetchCount += 1
        let page = try await base.fetch(request)
        guard fetchCount == 2 else { return page }
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        if delayedFailure,
           let snapshot = page.snapshots.first
        {
            return try CloudRecordPage(
                snapshots: [],
                failures: [CloudRecordFailure(
                    id: snapshot.id,
                    operation: .fetch,
                    error: .conflict(
                        snapshot.id,
                        expectedChangeTag: "c0",
                        actualChangeTag: snapshot.changeTag
                    )
                )]
            )
        }
        return page
    }

    func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        atomic: Bool
    ) async throws -> CloudModifyResult {
        try await base.modify(
            saving: mutations,
            deleting: recordIDs,
            atomic: atomic
        )
    }
}

private actor PausingFirstSaveCloudClient: CloudDatabaseClient {
    private let base: any CloudDatabaseClient
    private var modifyCount = 0
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(base: any CloudDatabaseClient) {
        self.base = base
    }

    func waitUntilFirstSaveBegins() async {
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func releaseFirstSave() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func fetch(_ request: CloudRecordFetchRequest) async throws -> CloudRecordPage {
        try await base.fetch(request)
    }

    func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        atomic: Bool
    ) async throws -> CloudModifyResult {
        modifyCount += 1
        if modifyCount == 1 {
            enteredContinuation?.resume()
            enteredContinuation = nil
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return try await base.modify(
            saving: mutations,
            deleting: recordIDs,
            atomic: atomic
        )
    }
}

private actor PausingFirstUpsertCloudClient: CloudDatabaseClient {
    private var records: [CloudRecordIdentifier: CloudRecordSnapshot]
    private var nextChangeTag = 0
    private var modifyCount = 0
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(initial: [CloudRecordSnapshot]) {
        records = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0) })
    }

    func waitUntilFirstSaveApplied() async {
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func releaseFirstSave() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func fetch(_ request: CloudRecordFetchRequest) async throws -> CloudRecordPage {
        try CloudRecordPage(
            snapshots: records.values
                .filter { $0.modelID == request.modelID }
                .sorted { $0.id.recordName < $1.id.recordName }
        )
    }

    func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        atomic: Bool
    ) async throws -> CloudModifyResult {
        modifyCount += 1
        var saved = [CloudRecordSnapshot]()
        for mutation in mutations {
            var fields = records[mutation.id]?.fields ?? [:]
            for fieldID in mutation.removedFields {
                fields.removeValue(forKey: fieldID)
            }
            fields.merge(mutation.values) { _, incoming in incoming }
            nextChangeTag += 1
            let snapshot = try CloudRecordSnapshot(
                id: mutation.id,
                modelID: mutation.modelID,
                changeTag: "c\(nextChangeTag)",
                fields: fields
            )
            records[mutation.id] = snapshot
            saved.append(snapshot)
        }
        var deleted = [CloudRecordIdentifier]()
        for id in recordIDs {
            guard records.removeValue(forKey: id) != nil else { continue }
            deleted.append(id)
        }
        let result = try CloudModifyResult(saved: saved, deleted: deleted)
        if modifyCount == 1 {
            enteredContinuation?.resume()
            enteredContinuation = nil
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return result
    }
}

private actor PausingFirstDeleteAfterApplyCloudClient: CloudDatabaseClient {
    private let base: any CloudDatabaseClient
    private var modifyCount = 0
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(base: any CloudDatabaseClient) {
        self.base = base
    }

    func waitUntilFirstDeleteApplied() async {
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func releaseFirstDelete() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func fetch(_ request: CloudRecordFetchRequest) async throws -> CloudRecordPage {
        try await base.fetch(request)
    }

    func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        atomic: Bool
    ) async throws -> CloudModifyResult {
        modifyCount += 1
        let result = try await base.modify(
            saving: mutations,
            deleting: recordIDs,
            atomic: atomic
        )
        if modifyCount == 1 {
            enteredContinuation?.resume()
            enteredContinuation = nil
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return result
    }
}

private actor PausingFirstSaveAfterApplyCloudClient: CloudDatabaseClient {
    private let base: any CloudDatabaseClient
    private var modifyCount = 0
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(base: any CloudDatabaseClient) {
        self.base = base
    }

    func waitUntilFirstSaveApplied() async {
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func releaseFirstSave() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func fetch(_ request: CloudRecordFetchRequest) async throws -> CloudRecordPage {
        try await base.fetch(request)
    }

    func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        atomic: Bool
    ) async throws -> CloudModifyResult {
        modifyCount += 1
        let result = try await base.modify(
            saving: mutations,
            deleting: recordIDs,
            atomic: atomic
        )
        if modifyCount == 1 {
            enteredContinuation?.resume()
            enteredContinuation = nil
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return result
    }
}

private actor PausingSaveAndDiscardFetchCloudClient: CloudDatabaseClient {
    private let base: any CloudDatabaseClient
    private var fetchCount = 0
    private var modifyCount = 0
    private var saveEnteredContinuation: CheckedContinuation<Void, Never>?
    private var saveReleaseContinuation: CheckedContinuation<Void, Never>?
    private var discardFetchEnteredContinuation: CheckedContinuation<Void, Never>?
    private var discardFetchReleaseContinuation: CheckedContinuation<Void, Never>?

    init(base: any CloudDatabaseClient) {
        self.base = base
    }

    func waitUntilFirstSaveApplied() async {
        await withCheckedContinuation { continuation in
            saveEnteredContinuation = continuation
        }
    }

    func releaseFirstSave() {
        saveReleaseContinuation?.resume()
        saveReleaseContinuation = nil
    }

    func waitUntilThirdFetchCaptured() async {
        await withCheckedContinuation { continuation in
            discardFetchEnteredContinuation = continuation
        }
    }

    func releaseThirdFetch() {
        discardFetchReleaseContinuation?.resume()
        discardFetchReleaseContinuation = nil
    }

    func fetch(_ request: CloudRecordFetchRequest) async throws -> CloudRecordPage {
        fetchCount += 1
        let page = try await base.fetch(request)
        guard fetchCount == 3 else { return page }
        discardFetchEnteredContinuation?.resume()
        discardFetchEnteredContinuation = nil
        await withCheckedContinuation { continuation in
            discardFetchReleaseContinuation = continuation
        }
        return page
    }

    func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        atomic: Bool
    ) async throws -> CloudModifyResult {
        modifyCount += 1
        let result = try await base.modify(
            saving: mutations,
            deleting: recordIDs,
            atomic: atomic
        )
        guard modifyCount == 1 else { return result }
        saveEnteredContinuation?.resume()
        saveEnteredContinuation = nil
        await withCheckedContinuation { continuation in
            saveReleaseContinuation = continuation
        }
        return result
    }
}

private actor PausingFirstSuccessSecondFailureCloudClient: CloudDatabaseClient {
    private let base: any CloudDatabaseClient
    private var modifyCount = 0
    private var firstEnteredContinuation: CheckedContinuation<Void, Never>?
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?
    private var secondEnteredContinuation: CheckedContinuation<Void, Never>?
    private var secondReleaseContinuation: CheckedContinuation<Void, Never>?

    init(base: any CloudDatabaseClient) {
        self.base = base
    }

    func waitUntilFirstSaveBegins() async {
        await withCheckedContinuation { continuation in
            firstEnteredContinuation = continuation
        }
    }

    func releaseFirstSave() {
        firstReleaseContinuation?.resume()
        firstReleaseContinuation = nil
    }

    func waitUntilSecondFailureBegins() async {
        await withCheckedContinuation { continuation in
            secondEnteredContinuation = continuation
        }
    }

    func releaseSecondFailure() {
        secondReleaseContinuation?.resume()
        secondReleaseContinuation = nil
    }

    func fetch(_ request: CloudRecordFetchRequest) async throws -> CloudRecordPage {
        try await base.fetch(request)
    }

    func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        atomic: Bool
    ) async throws -> CloudModifyResult {
        modifyCount += 1
        if modifyCount == 1 {
            firstEnteredContinuation?.resume()
            firstEnteredContinuation = nil
            await withCheckedContinuation { continuation in
                firstReleaseContinuation = continuation
            }
            return try await base.modify(
                saving: mutations,
                deleting: recordIDs,
                atomic: atomic
            )
        }

        guard modifyCount == 2,
              let id = mutations.first?.id ?? recordIDs.first
        else {
            return try await base.modify(
                saving: mutations,
                deleting: recordIDs,
                atomic: atomic
            )
        }
        secondEnteredContinuation?.resume()
        secondEnteredContinuation = nil
        await withCheckedContinuation { continuation in
            secondReleaseContinuation = continuation
        }
        return try CloudModifyResult(failures: [CloudRecordFailure(
            id: id,
            operation: mutations.isEmpty ? .delete : .save,
            error: .conflict(
                id,
                expectedChangeTag: "c1",
                actualChangeTag: "c2"
            )
        )])
    }
}

@MainActor
struct MacroCompileTests {
    @Test
    func scalarModelExpansionProvidesWorkingStorageAndMetadata() throws {
        let model = MacroCompileFixture()

        #expect(model.title == "")
        model.title = "hello"
        #expect(model.title == "hello")
        #expect(MacroCompileFixture.recordType == "ExplicitTask")
        #expect(MacroCompileFixture.cloudSchemaVersion == 3)
        #expect(MacroCompileFixture.cloudModelRuntimeMetadataIsStable)
        #expect(MacroCompileFixture.schemaMetadata.count == 2)
        #expect(MacroCompileFixture.schemaMetadata[0].name == "title")
        let metadata = try #require(MacroCompileFixture.schemaMetadata[0].metadata as? Schema.Attribute)
        #expect(metadata.options == [.unique])
        #expect(metadata.originalName == "legacy_title")
        #expect(String(describing: metadata.valueType) == "String")
        #expect(metadata.defaultValue as? String == "")
        let optionalMetadata = try #require(MacroCompileFixture.schemaMetadata[1].metadata as? Schema.Attribute)
        #expect(optionalMetadata.isOptional)
    }

    @Test
    func generatedModelUsesTypedContainerContextForRoundTrip() async throws {
        let schema = try CloudSchema(models: [MacroCompileFixture.cloudModelSchema()])
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        let configuration = try CloudStoreConfiguration(
            containerIdentifier: CloudContainerIdentifier("iCloud.example.Tests"),
            location: .privateDatabase(.default)
        )
        let container = try CloudModelContainer(
            schema: schema,
            configuration: configuration,
            client: client
        )
        let model = MacroCompileFixture()
        model.title = "typed"

        try container.mainContext.insert(model)
        let saved = try await container.mainContext.save()
        #expect(saved.saved.count == 1)
        #expect(try container.mainContext.state(for: model) == .clean)

        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let page = try await container.mainContext.fetch(descriptor)
        #expect(page.models.count == 1)
        #expect(page.models[0] === model)
        #expect(page.models[0].title == "typed")
    }

    @Test
    func fullRefreshClearsRemoteOptionalField() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let noteField = try CloudFieldIdentifier("note")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-refresh", zone: zone)
        let initial = try CloudRecordSnapshot(
            id: recordID,
            modelID: modelID,
            changeTag: "c1",
            fields: [
                titleField: .string("title"),
                noteField: .string("old")
            ]
        )
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [initial])
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.Refresh"),
                location: .privateDatabase(.default)
            ),
            client: client
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let page = try await container.mainContext.fetch(descriptor)
        let model = try #require(page.models.first)
        #expect(model.note == "old")

        _ = try await client.modify(
            saving: [CloudRecordMutation(
                id: recordID,
                modelID: modelID,
                removedFields: [noteField],
                policy: .update(expectedChangeTag: "c1")
            )],
            deleting: [],
            atomic: true
        )
        _ = try await container.mainContext.refresh(descriptor)

        #expect(model.note == nil)
        #expect(try container.mainContext.snapshot(for: model)?.fields[noteField] == nil)
    }

    @Test
    func typedSaveRequiresFullRefreshAfterProjectedFetch() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let noteField = try CloudFieldIdentifier("note")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-partial", zone: zone)
        let initial = try CloudRecordSnapshot(
            id: recordID,
            modelID: modelID,
            changeTag: "c1",
            fields: [
                titleField: .string("title"),
                noteField: .string("old note")
            ]
        )
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [initial])
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.Partial"),
                location: .privateDatabase(.default)
            ),
            client: client
        )
        let fullDescriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(fullDescriptor)).models.first)
        _ = try await client.modify(
            saving: [CloudRecordMutation(
                id: recordID,
                modelID: modelID,
                values: [noteField: .string("remote note")],
                policy: .update(expectedChangeTag: "c1")
            )],
            deleting: [],
            atomic: true
        )

        let projectedDescriptor = try CloudFetchDescriptor<MacroCompileFixture>(
            limit: 10,
            desiredFields: [titleField]
        )
        _ = try await container.mainContext.fetch(projectedDescriptor)
        do {
            _ = try await container.mainContext.refresh(
                projectedDescriptor,
                discardLocalChanges: true
            )
            Issue.record("Discarding local changes from a projected refresh must fail closed")
        } catch let error as CloudContextError {
            #expect(error == .partialRefreshRequiresFullFetch(modelID))
        } catch {
            Issue.record("Unexpected projected refresh error: \(error)")
        }
        model.title = "local title"

        do {
            _ = try await container.mainContext.save()
            Issue.record("A typed full-model save after a projected fetch must require a full refresh")
        } catch let error as CloudContextError {
            #expect(error == .partialSnapshotRequiresFullFetch(recordID))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func fullFetchRebasesEditAfterProjectedFetch() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let noteField = try CloudFieldIdentifier("note")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-partial-rebase", zone: zone)
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [
                    titleField: .string("title"),
                    noteField: .string("note")
                ]
            )
        ])
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.PartialRebase"),
                location: .privateDatabase(.default)
            ),
            client: client
        )
        let fullDescriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(fullDescriptor)).models.first)
        _ = try await container.mainContext.fetch(
            CloudFetchDescriptor<MacroCompileFixture>(
                limit: 10,
                desiredFields: [titleField]
            )
        )
        model.title = "local"
        _ = try await client.modify(
            saving: [CloudRecordMutation(
                id: recordID,
                modelID: modelID,
                values: [noteField: .string("remote note")],
                policy: .update(expectedChangeTag: "c1")
            )],
            deleting: [],
            atomic: true
        )

        _ = try await container.mainContext.fetch(fullDescriptor)
        #expect(model.title == "local")
        #expect(model.note == "remote note")
        #expect(try container.mainContext.state(for: model) == .dirty)
        let saved = try await container.mainContext.save()
        #expect(saved.saved.first?.fields[titleField] == .string("local"))
        #expect(saved.saved.first?.fields[noteField] == .string("remote note"))
    }

    @Test
    func fullFetchRecoversEditMadeBeforeProjectedFetch() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let noteField = try CloudFieldIdentifier("note")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-partial-before-edit", zone: zone)
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [
                    titleField: .string("title"),
                    noteField: .string("note")
                ]
            )
        ])
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.PartialBeforeEdit"),
                location: .privateDatabase(.default)
            ),
            client: client
        )
        let fullDescriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(fullDescriptor)).models.first)
        model.title = "local before projection"
        _ = try await container.mainContext.fetch(
            CloudFetchDescriptor<MacroCompileFixture>(
                limit: 10,
                desiredFields: [titleField]
            )
        )
        #expect(try container.mainContext.state(for: model) == .dirty)
        _ = try await client.modify(
            saving: [CloudRecordMutation(
                id: recordID,
                modelID: modelID,
                values: [noteField: .string("remote note")],
                policy: .update(expectedChangeTag: "c1")
            )],
            deleting: [],
            atomic: true
        )

        _ = try await container.mainContext.fetch(fullDescriptor)
        #expect(model.title == "local before projection")
        #expect(model.note == "remote note")
        #expect(try container.mainContext.state(for: model) == .dirty)
        let saved = try await container.mainContext.save()
        #expect(saved.saved.first?.fields[titleField] == .string("local before projection"))
        #expect(saved.saved.first?.fields[noteField] == .string("remote note"))
    }

    @Test
    func fullFetchPreservesNewerEditAfterProjectedRecovery() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let noteField = try CloudFieldIdentifier("note")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-partial-newer-edit", zone: zone)
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [
                    titleField: .string("title"),
                    noteField: .string("note")
                ]
            )
        ])
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.PartialNewerEdit"),
                location: .privateDatabase(.default)
            ),
            client: client
        )
        let fullDescriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(fullDescriptor)).models.first)
        model.title = "first local edit"
        _ = try await container.mainContext.fetch(
            CloudFetchDescriptor<MacroCompileFixture>(
                limit: 10,
                desiredFields: [titleField]
            )
        )
        #expect(try container.mainContext.state(for: model) == .dirty)
        model.title = "newer local edit"
        _ = try await client.modify(
            saving: [CloudRecordMutation(
                id: recordID,
                modelID: modelID,
                values: [noteField: .string("remote note")],
                policy: .update(expectedChangeTag: "c1")
            )],
            deleting: [],
            atomic: true
        )

        _ = try await container.mainContext.fetch(fullDescriptor)
        #expect(model.title == "newer local edit")
        #expect(model.note == "remote note")
        #expect(try container.mainContext.state(for: model) == .dirty)
        let saved = try await container.mainContext.save()
        #expect(saved.saved.first?.fields[titleField] == .string("newer local edit"))
        #expect(saved.saved.first?.fields[noteField] == .string("remote note"))
    }

    @Test
    func fullFetchKeepsConflictForNewerEditOnDirtyFullBaseline() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-full-newer-conflict", zone: zone)
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.FullNewerConflict"),
                location: .privateDatabase(.default)
            ),
            client: client
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(descriptor)).models.first)
        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [titleField: .string("first local edit")],
            policy: .update(expectedChangeTag: "c1")
        ))
        model.title = "newer local edit"
        _ = try await client.modify(
            saving: [CloudRecordMutation(
                id: recordID,
                modelID: modelID,
                values: [titleField: .string("remote")],
                policy: .update(expectedChangeTag: "c1")
            )],
            deleting: [],
            atomic: true
        )

        _ = try await container.mainContext.fetch(descriptor)
        #expect(model.title == "newer local edit")
        do {
            _ = try await container.mainContext.save()
            Issue.record("A dirty full-baseline edit must retain optimistic conflict semantics")
        } catch let error as CloudModelError {
            #expect(error == .conflict(
                recordID,
                expectedChangeTag: "c1",
                actualChangeTag: "c2"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func fullFetchPreservesNewerDirtyEditWhenItMatchesServer() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let noteField = try CloudFieldIdentifier("note")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-partial-matching-server", zone: zone)
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [
                    titleField: .string("title"),
                    noteField: .string("note")
                ]
            )
        ])
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.PartialMatchingServer"),
                location: .privateDatabase(.default)
            ),
            client: client
        )
        let fullDescriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(fullDescriptor)).models.first)
        model.title = "first local edit"
        _ = try await container.mainContext.fetch(
            CloudFetchDescriptor<MacroCompileFixture>(
                limit: 10,
                desiredFields: [titleField]
            )
        )
        model.title = "server title"
        _ = try await client.modify(
            saving: [CloudRecordMutation(
                id: recordID,
                modelID: modelID,
                values: [
                    titleField: .string("server title"),
                    noteField: .string("remote note")
                ],
                policy: .update(expectedChangeTag: "c1")
            )],
            deleting: [],
            atomic: true
        )

        _ = try await container.mainContext.fetch(fullDescriptor)
        #expect(model.title == "server title")
        #expect(model.note == "remote note")
        #expect(try container.mainContext.state(for: model) == .dirty)
        let saved = try await container.mainContext.save()
        #expect(saved.saved.first?.fields[titleField] == .string("server title"))
        #expect(saved.saved.first?.fields[noteField] == .string("remote note"))
    }

    @Test
    func fetchIgnoresStaleEditAfterLocalDeleteDuringRequest() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-delete-during-fetch", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = PausingFetchCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.DeleteDuringFetch"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(descriptor)).models.first)
        model.title = "stale direct edit"

        let inFlight = Task {
            _ = try await container.mainContext.fetch(descriptor)
        }
        await pausingClient.waitUntilFetchBegins()
        try container.mainContext.delete(model)
        await pausingClient.releaseFetch()
        _ = try await inFlight.value

        #expect(try container.mainContext.state(for: model) == .deleted)
        #expect(try await container.mainContext.save().deleted == [recordID])
    }

    @Test
    func staleFetchCannotReplaceBaselineAfterConcurrentSave() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-stale-fetch", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = PausingStaleFetchCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.StaleFetch"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(descriptor)).models.first)

        let staleFetch = Task {
            _ = try await container.mainContext.fetch(descriptor)
        }
        await pausingClient.waitUntilPageCaptured()
        model.title = "saved while fetch is in flight"
        let saved = try await container.mainContext.save()
        #expect(saved.saved.first?.changeTag == "c2")
        await pausingClient.releaseFetch()
        _ = try await staleFetch.value

        #expect(model.title == "saved while fetch is in flight")
        #expect(try container.mainContext.state(for: model) == .clean)
        #expect(try container.mainContext.snapshot(for: model)?.changeTag == "c2")
        #expect(try await container.mainContext.save().saved.isEmpty)
    }

    @Test
    func olderOverlappingFetchCannotReplaceNewerFetchBaseline() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-overlapping-fetch", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("old")]
            )
        ])
        let pausingClient = OutOfOrderFetchCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.OverlappingFetch"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(descriptor)).models.first)

        let olderFetch = Task {
            _ = try await container.mainContext.fetch(descriptor)
        }
        await pausingClient.waitUntilDelayedFetchBegins()
        _ = try await base.modify(
            saving: [CloudRecordMutation(
                id: recordID,
                modelID: modelID,
                values: [titleField: .string("new")],
                policy: .update(expectedChangeTag: "c1")
            )],
            deleting: [],
            atomic: true
        )
        _ = try await container.mainContext.fetch(descriptor)
        #expect(model.title == "new")
        #expect(try container.mainContext.snapshot(for: model)?.changeTag == "c2")

        await pausingClient.releaseDelayedFetch()
        _ = try await olderFetch.value
        #expect(model.title == "new")
        #expect(try container.mainContext.snapshot(for: model)?.changeTag == "c2")
    }

    @Test
    func olderFetchFailureCannotReplaceNewerSuccess() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-overlapping-failure", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("old")]
            )
        ])
        let pausingClient = OutOfOrderFetchCloudClient(base: base, delayedFailure: true)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.OverlappingFailure"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        _ = try await container.mainContext.fetch(descriptor)

        let olderFetch = Task {
            _ = try await container.mainContext.fetch(descriptor)
        }
        await pausingClient.waitUntilDelayedFetchBegins()
        _ = try await base.modify(
            saving: [CloudRecordMutation(
                id: recordID,
                modelID: modelID,
                values: [titleField: .string("new")],
                policy: .update(expectedChangeTag: "c1")
            )],
            deleting: [],
            atomic: true
        )
        _ = try await container.mainContext.fetch(descriptor)
        #expect(container.recordContext.lastFailure(for: recordID) == nil)

        await pausingClient.releaseDelayedFetch()
        _ = try await olderFetch.value
        #expect(container.recordContext.lastFailure(for: recordID) == nil)
        #expect(container.recordContext.conflict(for: recordID) == nil)
    }

    @Test
    func discardRefreshCannotBeSupersededByOverlappingFetch() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-discard-priority", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = OutOfOrderFetchCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.DiscardPriority"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(descriptor)).models.first)
        model.title = "local"
        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [titleField: .string("local")],
            policy: .update(expectedChangeTag: "c1")
        ))

        let discard = Task {
            _ = try await container.mainContext.refresh(
                descriptor,
                discardLocalChanges: true
            )
        }
        await pausingClient.waitUntilDelayedFetchBegins()
        _ = try await container.mainContext.fetch(descriptor)
        await pausingClient.releaseDelayedFetch()
        _ = try await discard.value

        #expect(model.title == "server")
        #expect(try container.mainContext.state(for: model) == .clean)
        #expect(try container.mainContext.snapshot(for: model)?.fields[titleField] == .string("server"))
    }

    @Test
    func olderNonAtomicSaveFailureCannotReplaceNewerSuccess() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-overlapping-save", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("old")]
            )
        ])
        let pausingClient = PausingFirstSaveCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.OverlappingSave"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(descriptor)).models.first)
        model.title = "older local title"
        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [titleField: .string("local")],
            policy: .update(expectedChangeTag: "c1")
        ))

        let olderSave = Task {
            try await container.recordContext.save(atomic: false)
        }
        await pausingClient.waitUntilFirstSaveBegins()
        let newerResult = try await container.recordContext.save(atomic: false)
        #expect(newerResult.failures.isEmpty)
        #expect(container.recordContext.state(for: recordID) == .clean)
        await pausingClient.releaseFirstSave()
        _ = try await olderSave.value

        #expect(container.recordContext.state(for: recordID) == .clean)
        #expect(container.recordContext.lastFailure(for: recordID) == nil)
        #expect(container.recordContext.conflict(for: recordID) == nil)
    }

    @Test
    func discardRefreshDoesNotDetachOverlappingDifferentModelFetch() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let secondaryModelID = try SecondaryCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let firstID = try CloudRecordIdentifier(recordName: "task-cross-model-discard", zone: zone)
        let secondID = try CloudRecordIdentifier(recordName: "secondary-cross-model-discard", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: firstID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("first")]
            ),
            CloudRecordSnapshot(
                id: secondID,
                modelID: secondaryModelID,
                changeTag: "c2",
                fields: [titleField: .string("second")]
            )
        ])
        let pausingClient = OutOfOrderFetchCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [
                MacroCompileFixture.cloudModelSchema(),
                SecondaryCompileFixture.cloudModelSchema()
            ]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.CrossModelDiscard"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let firstDescriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let secondDescriptor = try CloudFetchDescriptor<SecondaryCompileFixture>(limit: 10)
        _ = try await container.mainContext.fetch(firstDescriptor)

        let discard = Task {
            _ = try await container.mainContext.refresh(
                firstDescriptor,
                discardLocalChanges: true
            )
        }
        await pausingClient.waitUntilDelayedFetchBegins()
        let secondPage = try await container.mainContext.fetch(secondDescriptor)
        let secondModel = try #require(secondPage.models.first)
        #expect(try container.mainContext.state(for: secondModel) == .clean)

        await pausingClient.releaseDelayedFetch()
        _ = try await discard.value
        #expect(try container.mainContext.state(for: secondModel) == .clean)
    }

    @Test
    func discardRefreshDropsOlderFieldsFromOverlappingTypedFetch() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let noteField = try CloudFieldIdentifier("note")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-discard-overlap-fields", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [
                    titleField: .string("server title"),
                    noteField: .string("server note")
                ]
            )
        ])
        let pausingClient = OutOfOrderFetchCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.DiscardOverlapFields"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(descriptor)).models.first)
        model.title = "older local title"
        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [titleField: .string("older local title")],
            policy: .update(expectedChangeTag: "c1")
        ))

        let discard = Task {
            _ = try await container.mainContext.refresh(
                descriptor,
                discardLocalChanges: true
            )
        }
        await pausingClient.waitUntilDelayedFetchBegins()
        model.note = "newer note"
        _ = try await container.mainContext.fetch(descriptor)
        await pausingClient.releaseDelayedFetch()
        _ = try await discard.value

        #expect(model.title == "server title")
        #expect(model.note == "newer note")
        #expect(try container.mainContext.state(for: model) == .dirty)
    }

    @Test
    func typedSaveDoesNotRestageStaleSavedOutcome() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-typed-save-generation", zone: zone)
        let pausingClient = try PausingFirstUpsertCloudClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                fields: [titleField: .string("server")]
            )
        ])
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.TypedSaveGeneration"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let model = try #require(try await (container.mainContext.fetch(
            CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        )).models.first)
        model.title = "first value"

        let olderSave = Task {
            try await container.mainContext.save()
        }
        await pausingClient.waitUntilFirstSaveApplied()
        model.title = "second value"
        let newerResult = try await container.mainContext.save()
        #expect(newerResult.saved.first?.fields[titleField] == .string("second value"))

        await pausingClient.releaseFirstSave()
        _ = try await olderSave.value
        #expect(model.title == "second value")
        #expect(try container.mainContext.state(for: model) == .clean)
        let retry = try await container.mainContext.save()
        #expect(retry.saved.isEmpty)
    }

    @Test
    func discardRefreshCannotOverwriteNewerSuccessfulSave() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-discard-save-order", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = PausingStaleFetchCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.DiscardSaveOrder"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(descriptor)).models.first)
        model.title = "local"
        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [titleField: .string("local")],
            policy: .update(expectedChangeTag: "c1")
        ))

        let discard = Task {
            _ = try await container.mainContext.refresh(
                descriptor,
                discardLocalChanges: true
            )
        }
        await pausingClient.waitUntilPageCaptured()
        let saved = try await container.mainContext.save()
        #expect(saved.saved.first?.changeTag == "c2")
        await pausingClient.releaseFetch()
        _ = try await discard.value

        #expect(model.title == "local")
        #expect(try container.mainContext.state(for: model) == .clean)
        #expect(try container.mainContext.snapshot(for: model)?.changeTag == "c2")
    }

    @Test
    func staleSaveCannotOverwriteDiscardRefreshSnapshot() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-stale-save-discard", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = PausingFirstSaveAfterApplyCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.StaleSaveDiscard"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(descriptor)).models.first)
        model.title = "local"

        let saveTask = Task {
            try await container.mainContext.save()
        }
        await pausingClient.waitUntilFirstSaveApplied()
        let external = try await base.modify(
            saving: [CloudRecordMutation(
                id: recordID,
                modelID: modelID,
                values: [titleField: .string("external")],
                policy: .upsert
            )],
            deleting: [],
            atomic: true
        )
        #expect(external.saved.first?.fields[titleField] == .string("external"))

        _ = try await container.mainContext.refresh(
            descriptor,
            discardLocalChanges: true
        )
        #expect(model.title == "external")
        #expect(try container.mainContext.snapshot(for: model)?.changeTag == "c3")

        await pausingClient.releaseFirstSave()
        _ = try await saveTask.value

        #expect(model.title == "external")
        #expect(try container.mainContext.snapshot(for: model)?.changeTag == "c3")
        #expect(try container.mainContext.state(for: model) == .clean)
        #expect(try await container.mainContext.save().saved.isEmpty)
    }

    @Test
    func staleSaveCannotOverwriteNewerOrdinaryFetchSnapshot() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-stale-save-fetch", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = PausingFirstSaveAfterApplyCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.StaleSaveFetch"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(descriptor)).models.first)
        model.title = "local"

        let saveTask = Task {
            try await container.mainContext.save()
        }
        await pausingClient.waitUntilFirstSaveApplied()
        let external = try await base.modify(
            saving: [CloudRecordMutation(
                id: recordID,
                modelID: modelID,
                values: [titleField: .string("external")],
                policy: .upsert
            )],
            deleting: [],
            atomic: true
        )
        #expect(external.saved.first?.fields[titleField] == .string("external"))

        try container.mainContext.rollback()
        _ = try await container.mainContext.fetch(descriptor)
        #expect(model.title == "external")
        #expect(try container.mainContext.snapshot(for: model)?.changeTag == "c3")

        await pausingClient.releaseFirstSave()
        _ = try await saveTask.value

        #expect(model.title == "external")
        #expect(try container.mainContext.snapshot(for: model)?.changeTag == "c3")
        #expect(try container.mainContext.state(for: model) == .clean)
        #expect(try await container.mainContext.save().saved.isEmpty)
    }

    @Test
    func inFlightInsertSaveSurvivesNoOpFetch() async throws {
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        let pausingClient = PausingFirstSaveAfterApplyCloudClient(base: client)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.InsertFetchRace"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = MacroCompileFixture()
        model.title = "local"
        try container.mainContext.insert(model)

        let saveTask = Task {
            try await container.mainContext.save()
        }
        await pausingClient.waitUntilFirstSaveApplied()
        let fetched = try await container.mainContext.fetch(descriptor)
        #expect(fetched.models.contains { $0 === model })

        await pausingClient.releaseFirstSave()
        _ = try await saveTask.value
        #expect(try container.mainContext.state(for: model) == .clean)
        #expect(try container.mainContext.snapshot(for: model)?.changeTag != nil)
    }

    @Test
    func acceptedOldFetchCannotSuppressLaterSave() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-old-fetch-save", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = PausingFirstSaveCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.OldFetchSave"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let request = try CloudRecordFetchRequest(modelID: modelID, limit: 10)
        _ = try await container.recordContext.fetch(request)
        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [titleField: .string("local")],
            policy: .update(expectedChangeTag: "c1")
        ))

        let saveTask = Task {
            try await container.recordContext.save()
        }
        await pausingClient.waitUntilFirstSaveBegins()
        container.recordContext.discardChanges(for: recordID)
        _ = try await container.recordContext.fetch(request)

        await pausingClient.releaseFirstSave()
        _ = try await saveTask.value
        #expect(container.recordContext.state(for: recordID) == .clean)
        #expect(container.recordContext.snapshot(for: recordID)?.changeTag == "c2")
    }

    @Test
    func staleSaveCannotOverwriteNewerFetchAfterNewerMutation() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-stale-save-newer-mutation", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = PausingFirstSaveAfterApplyCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.StaleSaveNewerMutation"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let request = try CloudRecordFetchRequest(modelID: modelID, limit: 10)
        _ = try await container.recordContext.fetch(request)
        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [titleField: .string("older local")],
            policy: .update(expectedChangeTag: "c1")
        ))

        let saveTask = Task {
            try await container.recordContext.save()
        }
        await pausingClient.waitUntilFirstSaveApplied()
        container.recordContext.discardChanges(for: recordID)
        _ = try await base.modify(
            saving: [CloudRecordMutation(
                id: recordID,
                modelID: modelID,
                values: [titleField: .string("newer remote")],
                policy: .upsert
            )],
            deleting: [],
            atomic: true
        )
        _ = try await container.recordContext.fetch(request)
        #expect(container.recordContext.snapshot(for: recordID)?.changeTag == "c3")

        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [titleField: .string("newer local")],
            policy: .update(expectedChangeTag: "c3")
        ))
        await pausingClient.releaseFirstSave()
        _ = try await saveTask.value

        #expect(container.recordContext.baseline(for: recordID)?.changeTag == "c3")
        #expect(container.recordContext.snapshot(for: recordID)?.changeTag == "c3")
        #expect(container.recordContext.state(for: recordID) == .dirty)
        let retry = try await container.recordContext.save()
        #expect(retry.failures.isEmpty)
        #expect(retry.saved.first?.changeTag == "c4")
    }

    @Test
    func projectedOldFetchDoesNotSuppressInFlightSave() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let noteField = try CloudFieldIdentifier("note")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-projected-old-save", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [
                    titleField: .string("server title"),
                    noteField: .string("server note")
                ]
            )
        ])
        let pausingClient = PausingFirstSaveCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.ProjectedOldSave"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let request = try CloudRecordFetchRequest(modelID: modelID, limit: 10)
        _ = try await container.recordContext.fetch(request)
        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [titleField: .string("local title")],
            policy: .update(expectedChangeTag: "c1")
        ))

        let saveTask = Task {
            try await container.recordContext.save()
        }
        await pausingClient.waitUntilFirstSaveBegins()
        container.recordContext.discardChanges(for: recordID)
        _ = try await container.recordContext.fetch(
            CloudRecordFetchRequest(
                modelID: modelID,
                limit: 10,
                desiredFields: [titleField]
            )
        )
        #expect(container.recordContext.snapshot(for: recordID)?.changeTag == "c1")
        #expect(container.recordContext.snapshot(for: recordID)?.isPartial == true)

        await pausingClient.releaseFirstSave()
        _ = try await saveTask.value
        #expect(container.recordContext.state(for: recordID) == .clean)
        #expect(container.recordContext.snapshot(for: recordID)?.changeTag == "c2")
        #expect(container.recordContext.snapshot(for: recordID)?.isPartial == false)
    }

    @Test
    func rollbackAfterAppliedDeleteDoesNotLeaveGhostSnapshot() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-delete-rollback", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = PausingFirstDeleteAfterApplyCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.DeleteRollback"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let request = try CloudRecordFetchRequest(modelID: modelID, limit: 10)
        _ = try await container.recordContext.fetch(request)
        try container.recordContext.delete(recordID)

        let deleteTask = Task {
            try await container.recordContext.save()
        }
        await pausingClient.waitUntilFirstDeleteApplied()
        container.recordContext.discardChanges(for: recordID)
        #expect(container.recordContext.state(for: recordID) == .clean)

        await pausingClient.releaseFirstDelete()
        _ = try await deleteTask.value
        #expect(container.recordContext.state(for: recordID) == .deleted)
        #expect(container.recordContext.snapshot(for: recordID) == nil)
        #expect(container.recordContext.baseline(for: recordID) == nil)
    }

    @Test
    func skippedStaleSaveCannotBlockNewerDiscardRefresh() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-save-generation-bookkeeping", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("initial")]
            )
        ])
        let pausingClient = PausingSaveAndDiscardFetchCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.SaveGenerationBookkeeping"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let request = try CloudRecordFetchRequest(modelID: modelID, limit: 10)
        _ = try await container.recordContext.fetch(request)
        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [titleField: .string("old save")],
            policy: .update(expectedChangeTag: "c1")
        ))

        let saveTask = Task {
            try await container.recordContext.save()
        }
        await pausingClient.waitUntilFirstSaveApplied()
        container.recordContext.discardChanges(for: recordID)
        _ = try await base.modify(
            saving: [CloudRecordMutation(
                id: recordID,
                modelID: modelID,
                values: [titleField: .string("fetch version")],
                policy: .upsert
            )],
            deleting: [],
            atomic: true
        )
        _ = try await container.recordContext.fetch(request)
        _ = try await base.modify(
            saving: [CloudRecordMutation(
                id: recordID,
                modelID: modelID,
                values: [titleField: .string("discard version")],
                policy: .upsert
            )],
            deleting: [],
            atomic: true
        )

        let discardTask = Task {
            try await container.recordContext.refresh(
                request,
                discardLocalChanges: true
            )
        }
        await pausingClient.waitUntilThirdFetchCaptured()
        await pausingClient.releaseFirstSave()
        _ = try await saveTask.value
        await pausingClient.releaseThirdFetch()
        _ = try await discardTask.value

        #expect(container.recordContext.snapshot(for: recordID)?.changeTag == "c4")
        #expect(container.recordContext.snapshot(for: recordID)?.fields[titleField] == .string("discard version"))
        #expect(container.recordContext.state(for: recordID) == .clean)
    }

    @Test
    func directEditAfterRollbackOfAppliedDeleteIsRecreated() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-delete-direct-revival", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = PausingFirstDeleteAfterApplyCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.DeleteDirectRevival"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(descriptor)).models.first)
        try container.mainContext.delete(model)

        let deleteTask = Task {
            try await container.mainContext.save()
        }
        await pausingClient.waitUntilFirstDeleteApplied()
        try container.mainContext.rollback()
        model.title = "revived"

        await pausingClient.releaseFirstDelete()
        _ = try await deleteTask.value
        let retry = try await container.mainContext.save()
        #expect(retry.failures.isEmpty)
        #expect(retry.saved.first?.fields[titleField] == .string("revived"))
        #expect(try container.mainContext.state(for: model) == .clean)
    }

    @Test
    func rollbackRestorationBeforeAppliedDeleteDoesNotRecreateWithoutNewEdit() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-delete-rollback-restoration", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = PausingFirstDeleteAfterApplyCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.DeleteRollbackRestoration"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(descriptor)).models.first)
        model.title = "unsaved before delete"
        try container.mainContext.delete(model)

        let deleteTask = Task {
            try await container.mainContext.save()
        }
        await pausingClient.waitUntilFirstDeleteApplied()
        try container.mainContext.rollback()
        #expect(model.title == "server")

        await pausingClient.releaseFirstDelete()
        _ = try await deleteTask.value
        #expect(try container.mainContext.state(for: model) == .deleted)
        #expect(try await container.mainContext.save().saved.isEmpty)
    }

    @Test
    func rollbackMetadataIsReclaimedAfterDeletedModelLeavesIdentityMap() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-delete-rollback-metadata", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = PausingFirstDeleteAfterApplyCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.DeleteRollbackMetadata"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(descriptor)).models.first)
        try container.mainContext.delete(model)

        let deleteTask = Task {
            try await container.mainContext.save()
        }
        await pausingClient.waitUntilFirstDeleteApplied()
        try container.mainContext.rollback()
        await pausingClient.releaseFirstDelete()
        _ = try await deleteTask.value

        let generations = Mirror(reflecting: container.mainContext).children.first {
            $0.label == "rollbackGenerations"
        }?.value as? [CloudRecordIdentifier: UInt64]
        let restoredFields = Mirror(reflecting: container.mainContext).children.first {
            $0.label == "rollbackRestoredFields"
        }?.value as? [
            CloudRecordIdentifier: [CloudFieldIdentifier: CloudRecordValue]
        ]
        #expect(generations?.isEmpty == true)
        #expect(restoredFields?.isEmpty == true)
    }

    @Test
    func staleSaveFailureCannotBlockOlderSuccessfulSave() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-stale-save-failure", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = PausingFirstSuccessSecondFailureCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.StaleSaveFailure"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let request = try CloudRecordFetchRequest(modelID: modelID, limit: 10)
        _ = try await container.recordContext.fetch(request)
        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [titleField: .string("first")],
            policy: .update(expectedChangeTag: "c1")
        ))
        let olderSave = Task {
            try await container.recordContext.save(atomic: false)
        }
        await pausingClient.waitUntilFirstSaveBegins()

        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [titleField: .string("second")],
            policy: .update(expectedChangeTag: "c1")
        ))
        let newerSave = Task {
            try await container.recordContext.save(atomic: false)
        }
        await pausingClient.waitUntilSecondFailureBegins()
        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [titleField: .string("third")],
            policy: .update(expectedChangeTag: "c1")
        ))
        await pausingClient.releaseSecondFailure()
        let failure = try await newerSave.value
        #expect(failure.failures.count == 1)
        #expect(container.recordContext.lastFailure(for: recordID) == nil)

        await pausingClient.releaseFirstSave()
        _ = try await olderSave.value
        #expect(container.recordContext.baseline(for: recordID)?.changeTag == "c2")
        #expect(container.recordContext.state(for: recordID) == .dirty)
        let retry = try await container.recordContext.save()
        #expect(retry.failures.isEmpty)
        #expect(retry.saved.first?.changeTag == "c3")
    }

    @Test
    func projectedFetchOfInsertedVersionDoesNotSuppressSaveResult() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-insert-projected-version", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        let pausingClient = PausingFirstSaveAfterApplyCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.InsertProjectedVersion"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        try container.recordContext.insert(CloudRecordSnapshot(
            id: recordID,
            modelID: modelID,
            fields: [titleField: .string("inserted")]
        ))
        let saveTask = Task {
            try await container.recordContext.save()
        }
        await pausingClient.waitUntilFirstSaveApplied()
        container.recordContext.discardChanges(for: recordID)
        _ = try await container.recordContext.fetch(
            CloudRecordFetchRequest(
                modelID: modelID,
                limit: 10,
                desiredFields: [titleField]
            )
        )
        #expect(container.recordContext.snapshot(for: recordID)?.changeTag == "c1")
        #expect(container.recordContext.snapshot(for: recordID)?.isPartial == true)

        await pausingClient.releaseFirstSave()
        _ = try await saveTask.value
        #expect(container.recordContext.state(for: recordID) == .clean)
        #expect(container.recordContext.snapshot(for: recordID)?.changeTag == "c1")
        #expect(container.recordContext.snapshot(for: recordID)?.isPartial == false)
    }

    @Test
    func discardBarrierDoesNotDetachAnotherPageOfTheSameModel() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let firstID = try CloudRecordIdentifier(recordName: "task-page-a", zone: zone)
        let secondID = try CloudRecordIdentifier(recordName: "task-page-b", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: firstID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("first")]
            ),
            CloudRecordSnapshot(
                id: secondID,
                modelID: modelID,
                changeTag: "c2",
                fields: [titleField: .string("second")]
            )
        ])
        let pausingClient = PausingStaleFetchCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.DiscardPageScope"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let firstDescriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 1)
        let firstPage = try await container.mainContext.fetch(firstDescriptor)
        let cursor = try #require(firstPage.nextCursor)

        let discard = Task {
            _ = try await container.mainContext.refresh(
                firstDescriptor,
                discardLocalChanges: true
            )
        }
        await pausingClient.waitUntilPageCaptured()
        let secondDescriptor = try CloudFetchDescriptor<MacroCompileFixture>(
            limit: 1,
            cursor: cursor
        )
        let secondPage = try await container.mainContext.fetch(secondDescriptor)
        let secondModel = try #require(secondPage.models.first)
        #expect(secondModel.title == "second")
        #expect(try container.mainContext.state(for: secondModel) == .clean)

        await pausingClient.releaseFetch()
        _ = try await discard.value
        #expect(try container.mainContext.state(for: secondModel) == .clean)
    }

    @Test
    func detachDuringDiscardRefreshRemainsDetached() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-detach-discard", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = PausingFetchCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.DetachDiscard"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(descriptor)).models.first)

        let refresh = Task {
            _ = try await container.mainContext.refresh(
                descriptor,
                discardLocalChanges: true
            )
        }
        await pausingClient.waitUntilFetchBegins()
        try container.recordContext.detach(recordID)
        await pausingClient.releaseFetch()
        _ = try await refresh.value

        #expect(try container.mainContext.state(for: model) == .detached)
        #expect(try container.mainContext.snapshot(for: model) == nil)
    }

    @Test
    func staleTypedDeleteCannotRemoveRecreatedModel() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-stale-delete", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("old")]
            )
        ])
        let pausingClient = PausingFirstDeleteAfterApplyCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.StaleDelete"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(descriptor)).models.first)
        try container.mainContext.delete(model)
        let olderDelete = Task {
            try await container.mainContext.save()
        }
        await pausingClient.waitUntilFirstDeleteApplied()

        container.recordContext.discardChanges(for: recordID)
        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [titleField: .string("recreated")],
            policy: .upsert
        ))
        _ = try await container.recordContext.save()
        #expect(container.recordContext.snapshot(for: recordID)?.fields[titleField] == .string("recreated"))
        try model.applyCloudRecordSnapshot(#require(container.recordContext.snapshot(for: recordID)))
        await pausingClient.releaseFirstDelete()
        _ = try await olderDelete.value
        #expect(container.recordContext.snapshot(for: recordID)?.fields[titleField] == .string("recreated"))

        let fetched = try await container.mainContext.fetch(descriptor)
        let refetched = try #require(fetched.models.first)
        #expect(refetched === model)
        #expect(refetched.title == "recreated")
        #expect(try container.mainContext.state(for: model) == .clean)
    }

    @Test
    func discardDropsCleanEquivalentOverlappingMutation() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let noteField = try CloudFieldIdentifier("note")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-discard-noop", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [
                    titleField: .string("server title"),
                    noteField: .string("server note")
                ]
            )
        ])
        let pausingClient = OutOfOrderFetchCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.DiscardNoop"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(descriptor)).models.first)
        model.title = "older local title"
        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [titleField: .string("older local title")],
            policy: .update(expectedChangeTag: "c1")
        ))

        let discard = Task {
            _ = try await container.mainContext.refresh(
                descriptor,
                discardLocalChanges: true
            )
        }
        await pausingClient.waitUntilDelayedFetchBegins()
        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [noteField: .string("newer note")],
            policy: .update(expectedChangeTag: "c1")
        ))
        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [noteField: .string("server note")],
            policy: .update(expectedChangeTag: "c1")
        ))
        await pausingClient.releaseDelayedFetch()
        _ = try await discard.value

        #expect(container.recordContext.snapshot(for: recordID)?.fields[titleField] == .string("server title"))
        #expect(container.recordContext.snapshot(for: recordID)?.fields[noteField] == .string("server note"))
        #expect(container.recordContext.state(for: recordID) == .clean)
        #expect(try await container.recordContext.save().saved.isEmpty)
    }

    @Test
    func fetchPreservesDirectModelEditBeforeSave() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-fetch-edit", zone: zone)
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.FetchEdit"),
                location: .privateDatabase(.default)
            ),
            client: client
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let model = try #require(try await (container.mainContext.fetch(descriptor)).models.first)
        model.title = "local"

        // The second fetch must stage the direct setter before merging its
        // server snapshot, so the local value remains dirty and visible.
        _ = try await container.mainContext.fetch(descriptor)
        #expect(model.title == "local")
        #expect(try container.mainContext.state(for: model) == .dirty)
        #expect(try await container.mainContext.save().saved.first?.fields[titleField] == .string("local"))
    }

    @Test
    func fetchPreservesDirectModelEditMadeWhileRequestIsInFlight() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-fetch-in-flight", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = PausingFetchCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.FetchInFlight"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let initial = try await container.mainContext.fetch(descriptor)
        let model = try #require(initial.models.first)

        let inFlight = Task {
            _ = try await container.mainContext.fetch(descriptor)
        }
        await pausingClient.waitUntilFetchBegins()
        model.title = "during fetch"
        await pausingClient.releaseFetch()
        _ = try await inFlight.value

        #expect(model.title == "during fetch")
        #expect(try container.mainContext.state(for: model) == .dirty)
        #expect(try await container.mainContext.save().saved.first?.fields[titleField] == .string("during fetch"))
    }

    @Test
    func discardRefreshPreservesNewerEditMadeWhileRequestIsInFlight() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-discard-in-flight", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = PausingFetchCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.DiscardInFlight"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let initial = try await container.mainContext.fetch(descriptor)
        let model = try #require(initial.models.first)

        let inFlight = Task {
            _ = try await container.mainContext.refresh(
                descriptor,
                discardLocalChanges: true
            )
        }
        await pausingClient.waitUntilFetchBegins()
        model.title = "during discard refresh"
        await pausingClient.releaseFetch()
        _ = try await inFlight.value

        #expect(model.title == "during discard refresh")
        #expect(try container.mainContext.state(for: model) == .dirty)
        #expect(try await container.mainContext.save().saved.first?.fields[titleField] == .string("during discard refresh"))
    }

    @Test
    func discardRefreshPreservesNewerEditForDirtyModel() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-discard-dirty-in-flight", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = PausingFetchCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.DiscardDirtyInFlight"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let initial = try await container.mainContext.fetch(descriptor)
        let model = try #require(initial.models.first)
        model.title = "before refresh"
        try container.recordContext.stage(CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [titleField: .string("before refresh")],
            policy: .update(expectedChangeTag: "c1")
        ))
        #expect(try container.mainContext.state(for: model) == .dirty)

        let inFlight = Task {
            _ = try await container.mainContext.refresh(
                descriptor,
                discardLocalChanges: true
            )
        }
        await pausingClient.waitUntilFetchBegins()
        model.title = "during dirty discard refresh"
        await pausingClient.releaseFetch()
        _ = try await inFlight.value

        #expect(model.title == "during dirty discard refresh")
        #expect(try container.mainContext.state(for: model) == .dirty)
        #expect(try await container.mainContext.save().saved.first?.fields[titleField] == .string("during dirty discard refresh"))
    }

    @Test
    func discardRefreshPreservesDeleteMadeWhileRequestIsInFlight() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-discard-delete-in-flight", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("server")]
            )
        ])
        let pausingClient = PausingFetchCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.DiscardDeleteInFlight"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let initial = try await container.mainContext.fetch(descriptor)
        let model = try #require(initial.models.first)

        let inFlight = Task {
            _ = try await container.mainContext.refresh(
                descriptor,
                discardLocalChanges: true
            )
        }
        await pausingClient.waitUntilFetchBegins()
        try container.mainContext.delete(model)
        await pausingClient.releaseFetch()
        _ = try await inFlight.value

        #expect(try container.mainContext.state(for: model) == .deleted)
        let saved = try await container.mainContext.save()
        #expect(saved.deleted == [recordID])
    }

    @Test
    func discardRefreshMaterializesRemoteAfterTypedInsertedIDCollision() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let model = MacroCompileFixture()
        let recordID = try CloudRecordIdentifier(recordName: model.recordID.recordName, zone: zone)
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("remote")]
            )
        ])
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.TypedCollision"),
                location: .privateDatabase(.default)
            ),
            client: client
        )
        try container.mainContext.insert(model)
        _ = try await container.mainContext.refresh(
            CloudFetchDescriptor<MacroCompileFixture>(limit: 10),
            discardLocalChanges: true
        )

        #expect(model.title == "remote")
        #expect(try container.mainContext.state(for: model) == .clean)
        #expect(try container.mainContext.snapshot(for: model)?.fields[titleField] == .string("remote"))
    }

    @Test
    func matchingServerValueDuringFetchDoesNotRemainDirty() async throws {
        let modelID = try MacroCompileFixture.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("_defaultZone")
        let recordID = try CloudRecordIdentifier(recordName: "task-fetch-matching-server", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: recordID,
                modelID: modelID,
                changeTag: "c1",
                fields: [titleField: .string("old")]
            )
        ])
        let pausingClient = PausingFetchCloudClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.MatchingServer"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let descriptor = try CloudFetchDescriptor<MacroCompileFixture>(limit: 10)
        let initial = try await container.mainContext.fetch(descriptor)
        let model = try #require(initial.models.first)

        let inFlight = Task {
            _ = try await container.mainContext.fetch(descriptor)
        }
        await pausingClient.waitUntilFetchBegins()
        _ = try await base.modify(
            saving: [CloudRecordMutation(
                id: recordID,
                modelID: modelID,
                values: [titleField: .string("new")],
                policy: .update(expectedChangeTag: "c1")
            )],
            deleting: [],
            atomic: true
        )
        model.title = "new"
        await pausingClient.releaseFetch()
        _ = try await inFlight.value

        #expect(model.title == "new")
        #expect(try container.mainContext.state(for: model) == .clean)
        #expect(try await container.mainContext.save().saved.isEmpty)
    }

    @Test
    func editDuringSaveRemainsDirtyAfterOlderRequestCompletes() async throws {
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        let pausingClient = PausingCloudClient(base: client)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.Race"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let model = MacroCompileFixture()
        model.title = "before"
        try container.mainContext.insert(model)

        let saveTask = Task { try await container.mainContext.save() }
        await pausingClient.waitUntilModifyBegins()
        model.title = "during"
        await pausingClient.releaseModify()
        _ = try await saveTask.value

        #expect(model.title == "during")
        #expect(try container.mainContext.state(for: model) == .dirty)
        #expect(try container.mainContext.snapshot(for: model)?.fields[
            CloudFieldIdentifier("title")
        ] == .string("during"))
    }

    @Test
    func rollbackDuringInFlightInsertSaveReattachesSuccessfulResult() async throws {
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        let pausingClient = PausingFirstSaveCloudClient(base: client)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [MacroCompileFixture.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.RollbackInsert"),
                location: .privateDatabase(.default)
            ),
            client: pausingClient
        )
        let model = MacroCompileFixture()
        model.title = "before"
        try container.mainContext.insert(model)

        let saveTask = Task {
            try await container.mainContext.save()
        }
        await pausingClient.waitUntilFirstSaveBegins()
        try container.mainContext.rollback()
        #expect(try container.mainContext.state(for: model) == .detached)

        await pausingClient.releaseFirstSave()
        let result = try await saveTask.value
        #expect(result.saved.count == 1)
        #expect(try container.mainContext.state(for: model) == .clean)
        #expect(try container.mainContext.snapshot(for: model)?.changeTag != nil)

        model.title = "after"
        let retry = try await container.mainContext.save()
        #expect(retry.saved.count == 1)
        #expect(try container.mainContext.state(for: model) == .clean)
    }
}
