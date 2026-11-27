import CKSwiftData
import Foundation
import Testing

@CloudModel
final class UnchangedAssetItem {
    var title: String = ""
    @Attribute(.externalStorage)
    var payload: Data
}

/// A client that behaves like the CloudKit adapter for assets: a mutation may
/// carry an asset value only together with a staged upload.
private actor AssetStrictClient: CloudDatabaseClient {
    let base: CKSwiftDataTesting.InMemoryCloudDatabaseClient
    private(set) var mutations: [CloudRecordMutation] = []

    init(base: CKSwiftDataTesting.InMemoryCloudDatabaseClient) {
        self.base = base
    }

    func fetch(_ request: CloudRecordFetchRequest) async throws -> CloudRecordPage {
        try await base.fetch(request)
    }

    func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        atomic: Bool
    ) async throws -> CloudModifyResult {
        self.mutations.append(contentsOf: mutations)
        for mutation in mutations {
            for (fieldID, value) in mutation.values {
                if case .asset = value {
                    throw CloudModelError.invalidRequest(
                        "asset field \(fieldID.rawValue) was sent without an upload"
                    )
                }
            }
        }
        return try await base.modify(saving: mutations, deleting: recordIDs, atomic: atomic)
    }
}

struct CloudUnchangedAssetTests {
    @MainActor
    @Test
    func editingAnotherFieldKeepsTheRemoteAssetAndDoesNotResendIt() async throws {
        let zone = try CloudZoneIdentifier("_defaultZone")
        let modelID = try UnchangedAssetItem.cloudModelIdentifier()
        let title = try CloudFieldIdentifier("title")
        let payload = try CloudFieldIdentifier("payload")
        let id = try CloudRecordIdentifier(recordName: "item-1", zone: zone)
        let reference = try CloudAssetReference(assetID: "payload.data", byteCount: 3)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(
                id: id,
                modelID: modelID,
                changeTag: "c1",
                fields: [title: .string("before"), payload: .asset(reference)]
            )
        ])
        let client = AssetStrictClient(base: base)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [UnchangedAssetItem.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.Assets"),
                location: .privateDatabase(.default)
            ),
            client: client
        )
        let page = try await container.mainContext.fetch(
            CloudFetchDescriptor<UnchangedAssetItem>(limit: 10)
        )
        let item = try #require(page.models.first)

        item.title = "after"
        let result = try await container.mainContext.save()

        #expect(result.failures.isEmpty)
        let sent = await client.mutations
        #expect(sent.count == 1)
        #expect(sent.first?.values[title] == .string("after"))
        #expect(sent.first?.values[payload] == nil)

        let stored = try await base.fetch(CloudRecordFetchRequest(modelID: modelID, limit: 10))
        let record = try #require(stored.snapshots.first)
        #expect(record.fields[title] == .string("after"))
        #expect(record.fields[payload] == .asset(reference))
    }
}
