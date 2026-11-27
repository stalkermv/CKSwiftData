import CKSwiftData
import Foundation
import Testing

struct CloudConflictDeletionTests {
    @MainActor
    @Test
    func acceptingAServerDeletionUnbindsTheModel() async throws {
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [DeclaredRecordTypeDefault.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.ConflictDeletion"),
                location: .privateDatabase(.default)
            ),
            client: client
        )
        let context = container.mainContext
        let modelID = try DeclaredRecordTypeDefault.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let model = DeclaredRecordTypeDefault()
        model.title = "saved"
        try context.insert(model)
        _ = try await context.save()
        let id = try model.cloudRecordIdentifier(in: context.zone)

        // Another device deletes the record, then this device edits it.
        _ = try await client.modify(saving: [], deleting: [id], atomic: true)
        model.title = "edited after the remote delete"
        let failed = try await context.save(atomic: false)
        #expect(failed.failures.map(\.id) == [id])
        let conflict = try #require(try context.conflict(for: model))
        #expect(conflict.record.server == nil)

        try context.resolveConflict(for: model, using: .useServer)
        #expect(try context.state(for: model) == .deleted)

        // The record is recreated remotely under the same name. Had the
        // context kept the deleted model bound, the fetch would hand back
        // that stale instance with its discarded edit.
        _ = try await client.modify(
            saving: [CloudRecordMutation(
                id: id,
                modelID: modelID,
                values: [titleField: .string("recreated")],
                policy: .insert
            )],
            deleting: [],
            atomic: true
        )
        let page = try await context.fetch(CloudFetchDescriptor<DeclaredRecordTypeDefault>(limit: 10))
        let fetched = try #require(page.models.first)
        #expect(fetched !== model)
        #expect(fetched.title == "recreated")
    }
}
