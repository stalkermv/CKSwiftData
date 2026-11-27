import CKSwiftData
import Foundation
import Testing

struct CloudFetchProjectionTests {
    private let modelID: CloudModelIdentifier
    private let title: CloudFieldIdentifier
    private let schema: CloudSchema
    private let configuration: CloudStoreConfiguration

    init() throws {
        modelID = try CloudModelIdentifier("Task")
        title = try CloudFieldIdentifier("title")
        schema = try CloudSchema(models: [
            CloudModelSchema(
                id: modelID,
                recordType: modelID,
                fields: [
                    .attribute(
                        CloudAttributeSchema(
                            id: title,
                            recordName: title,
                            kind: .scalar
                        )
                    )
                ]
            )
        ])
        configuration = try CloudStoreConfiguration(
            containerIdentifier: CloudContainerIdentifier("iCloud.example.Projection"),
            location: .privateDatabase(.default)
        )
    }

    private func seededClient() async throws -> CKSwiftDataTesting.InMemoryCloudDatabaseClient {
        let zone = try CloudZoneIdentifier("_defaultZone")
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        _ = try await client.modify(
            saving: [
                CloudRecordMutation(
                    id: CloudRecordIdentifier(recordName: "task-1", zone: zone),
                    modelID: modelID,
                    values: [title: .string("one")],
                    policy: .insert
                )
            ],
            deleting: [],
            atomic: true
        )
        return client
    }

    @Test
    func unknownDesiredFieldIsRejectedBeforeTheClientSeesIt() async throws {
        let unknown = try CloudFieldIdentifier("missing")
        let request = try CloudRecordFetchRequest(modelID: modelID, desiredFields: [unknown])
        let inMemory = try await seededClient()
        let scripted = try await CKSwiftDataTesting.ScriptedCloudDatabaseClient(base: seededClient())
        let clients: [any CloudDatabaseClient] = [inMemory, scripted]

        for client in clients {
            let store = CloudKitRecordStore(
                schema: schema,
                configuration: configuration,
                client: client
            )
            do {
                _ = try await store.fetch(request)
                Issue.record("An unknown desired field must be rejected")
            } catch let error as CloudModelError {
                #expect(error == .invalidRequest("desired field missing is not present in the schema"))
            }
        }
    }

    @Test
    func knownDesiredFieldsStillProject() async throws {
        let client = try await seededClient()
        let store = CloudKitRecordStore(
            schema: schema,
            configuration: configuration,
            client: client
        )

        let page = try await store.fetch(
            CloudRecordFetchRequest(modelID: modelID, desiredFields: [title])
        )

        #expect(page.snapshots.count == 1)
        #expect(page.snapshots.first?.fields[title] == .string("one"))
    }
}
