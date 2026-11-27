import CKSwiftData
import Foundation
import Testing

struct CloudDeleteUnsavedInsertTests {
    @MainActor
    private func makeContainer() throws -> (
        CloudModelContainer,
        CKSwiftDataTesting.InMemoryCloudDatabaseClient
    ) {
        let schema = try CloudSchema(models: [DeclaredRecordTypeDefault.cloudModelSchema()])
        let configuration = try CloudStoreConfiguration(
            containerIdentifier: CloudContainerIdentifier("iCloud.example.DeleteInsert"),
            location: .privateDatabase(.default)
        )
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        let container = try CloudModelContainer(
            schema: schema,
            configuration: configuration,
            client: client
        )
        return (container, client)
    }

    private func storedTitles(in client: CKSwiftDataTesting.InMemoryCloudDatabaseClient) async throws -> [String] {
        let modelID = try DeclaredRecordTypeDefault.cloudModelIdentifier()
        let page = try await client.fetch(CloudRecordFetchRequest(modelID: modelID, limit: 10))
        let title = try CloudFieldIdentifier("title")
        return page.snapshots.compactMap { snapshot in
            if case let .string(value) = snapshot.fields[title] { return value }
            return nil
        }
    }

    @MainActor
    @Test
    func deletingAnUnsavedInsertDiscardsItLocally() async throws {
        let (container, client) = try makeContainer()
        let context = container.mainContext
        let discarded = DeclaredRecordTypeDefault()
        discarded.title = "discarded"
        let kept = DeclaredRecordTypeDefault()
        kept.title = "kept"
        try context.insert(discarded)
        try context.insert(kept)
        let discardedID = try discarded.cloudRecordIdentifier(in: context.zone)

        try context.delete(discarded)
        #expect(context.recordContext.state(for: discardedID) == .detached)

        let result = try await context.save()

        #expect(result.failures.isEmpty)
        #expect(result.deleted.isEmpty)
        #expect(result.saved.count == 1)
        #expect(try await storedTitles(in: client) == ["kept"])
    }

    @MainActor
    @Test
    func deletingASavedRecordStillSendsARemoteDelete() async throws {
        let (container, client) = try makeContainer()
        let context = container.mainContext
        let model = DeclaredRecordTypeDefault()
        model.title = "saved"
        try context.insert(model)
        _ = try await context.save()
        #expect(try await storedTitles(in: client) == ["saved"])

        try context.delete(model)
        let result = try await context.save()

        #expect(result.failures.isEmpty)
        #expect(result.deleted.count == 1)
        #expect(try await storedTitles(in: client).isEmpty)
    }
}
