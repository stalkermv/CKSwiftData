import CKSwiftData
import Foundation
import Testing

/// Serves pages from a base client but reports one record as unreadable.
private actor UnreadableRecordClient: CloudDatabaseClient {
    private let base: any CloudDatabaseClient
    private let unreadable: CloudRecordIdentifier
    private let error: CloudModelError

    init(
        base: any CloudDatabaseClient,
        unreadable: CloudRecordIdentifier,
        error: CloudModelError
    ) {
        self.base = base
        self.unreadable = unreadable
        self.error = error
    }

    func fetch(_ request: CloudRecordFetchRequest) async throws -> CloudRecordPage {
        let page = try await base.fetch(request)
        guard page.snapshots.contains(where: { $0.id == unreadable }) else { return page }
        return try CloudRecordPage(
            snapshots: page.snapshots.filter { $0.id != unreadable },
            nextCursor: page.nextCursor,
            failures: page.failures + [CloudRecordFailure(
                id: unreadable,
                operation: .fetch,
                error: error
            )]
        )
    }

    func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        atomic: Bool
    ) async throws -> CloudModifyResult {
        try await base.modify(saving: mutations, deleting: recordIDs, atomic: atomic)
    }
}

struct CloudFetchFailureTests {
    private let zone: CloudZoneIdentifier
    private let error = CloudModelError.retryable("zone busy", retryAfter: nil)

    init() throws {
        zone = try CloudZoneIdentifier("private")
    }

    @MainActor
    @Test
    func discardingRefreshRecordsFailuresLikeAnOrdinaryFetch() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let readable = try CloudRecordIdentifier(recordName: "task-1", zone: zone)
        let unreadable = try CloudRecordIdentifier(recordName: "task-2", zone: zone)
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [
            CloudRecordSnapshot(id: readable, modelID: modelID, fields: [title: .string("one")]),
            CloudRecordSnapshot(id: unreadable, modelID: modelID, fields: [title: .string("two")])
        ])
        let context = try CloudRecordContext(
            schema: CloudSchema(models: [
                CloudModelSchema(id: modelID, recordType: modelID, fields: [
                    .attribute(CloudAttributeSchema(id: title, recordName: title, kind: .scalar))
                ])
            ]),
            configuration: configuration(),
            client: UnreadableRecordClient(base: base, unreadable: unreadable, error: error)
        )

        let page = try await context.refresh(
            CloudRecordFetchRequest(modelID: modelID),
            discardLocalChanges: true
        )

        #expect(page.failures.map(\.id) == [unreadable])
        #expect(context.lastFailure(for: unreadable) == error)
        #expect(context.lastFailure(for: readable) == nil)
    }

    @Test
    func edgeReaderReportsUnreadableEdgeRecords() async throws {
        let edgeModel = try CloudModelIdentifier("RelationshipEdge")
        let sourceField = try CloudFieldIdentifier("source")
        let relationshipField = try CloudFieldIdentifier("relationship")
        let targetField = try CloudFieldIdentifier("target")
        let relationship = try CloudFieldIdentifier("children")
        let source = try CloudRecordIdentifier(recordName: "source", zone: zone)
        let edges = try ["edge-a", "edge-b"].map { try CloudRecordIdentifier(recordName: $0, zone: zone) }
        let snapshots = try edges.enumerated().map { index, id in
            try CloudRecordSnapshot(id: id, modelID: edgeModel, fields: [
                sourceField: .reference(source),
                relationshipField: .string(relationship.rawValue),
                targetField: .reference(CloudRecordIdentifier(recordName: "target-\(index)", zone: zone))
            ])
        }
        let fields: [CloudFieldSchema] = try [sourceField, relationshipField, targetField].map {
            try .attribute(CloudAttributeSchema(id: $0, recordName: $0, kind: .scalar))
        }
        let store = try CloudKitRecordStore(
            schema: CloudSchema(models: [
                CloudModelSchema(id: edgeModel, recordType: edgeModel, fields: fields)
            ]),
            configuration: configuration(),
            client: UnreadableRecordClient(
                base: CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: snapshots),
                unreadable: edges[1],
                error: error
            )
        )
        let reader = CloudRelationshipEdgeReader(
            store: store,
            edgeModelID: edgeModel,
            sourceField: sourceField,
            relationshipField: relationshipField,
            targetField: targetField
        )

        let page = try await reader.fetch(CloudRelationshipEdgeQuery(
            source: source,
            relationship: relationship,
            limit: 10
        ))

        #expect(page.edges.count == 1)
        #expect(page.failures.map(\.id) == [edges[1]])
        #expect(page.failures.first?.error == error)
    }

    @Test
    func edgePageDecodesWithoutAFailureList() throws {
        let page = try JSONDecoder().decode(
            CloudRelationshipEdgePage.self,
            from: Data(#"{"edges":[]}"#.utf8)
        )
        #expect(page.edges.isEmpty)
        #expect(page.failures.isEmpty)
    }

    private func configuration() throws -> CloudStoreConfiguration {
        try CloudStoreConfiguration(
            containerIdentifier: CloudContainerIdentifier("iCloud.example.FetchFailures"),
            location: .privateDatabase(.custom(zone))
        )
    }
}
