import CKSwiftData
import Foundation
import Testing

struct InMemoryCloudDatabaseClientTests {
    @Test
    func insertsFetchesDesiredFieldsAndPaginatesInStableOrder() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let zone = try CloudZoneIdentifier("private")
        let title = try CloudFieldIdentifier("title")
        let completed = try CloudFieldIdentifier("completed")
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()

        let mutations = try ["task-b", "task-a", "task-c"].map { recordName in
            try CloudRecordMutation(
                id: CloudRecordIdentifier(recordName: recordName, zone: zone),
                modelID: modelID,
                values: [
                    title: .string(recordName),
                    completed: .bool(false)
                ],
                policy: .insert
            )
        }
        let save = try await client.modify(saving: mutations, deleting: [], atomic: true)
        #expect(save.saved.map(\.changeTag) == ["c1", "c2", "c3"])

        let firstRequest = try CloudRecordFetchRequest(
            modelID: modelID,
            limit: 2,
            desiredFields: [title]
        )
        let firstPage = try await client.fetch(firstRequest)
        #expect(firstPage.snapshots.map(\.id.recordName) == ["task-a", "task-b"])
        #expect(firstPage.snapshots.allSatisfy { Set($0.fields.keys) == [title] })
        #expect(firstPage.nextCursor != nil)

        let secondRequest = try CloudRecordFetchRequest(
            modelID: modelID,
            limit: 2,
            cursor: firstPage.nextCursor
        )
        let secondPage = try await client.fetch(secondRequest)
        #expect(secondPage.snapshots.map(\.id.recordName) == ["task-c"])
        #expect(secondPage.nextCursor == nil)
    }

    @Test
    func cachedPaginationOrderReflectsStoreMutations() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let zone = try CloudZoneIdentifier("private")
        let title = try CloudFieldIdentifier("title")
        let firstID = try CloudRecordIdentifier(recordName: "task-a", zone: zone)
        let lastID = try CloudRecordIdentifier(recordName: "task-c", zone: zone)
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(
            initial: [
                CloudRecordSnapshot(
                    id: firstID,
                    modelID: modelID,
                    changeTag: "c1",
                    fields: [title: .string("a")]
                ),
                CloudRecordSnapshot(
                    id: lastID,
                    modelID: modelID,
                    changeTag: "c2",
                    fields: [title: .string("c")]
                )
            ]
        )

        _ = try await client.fetch(
            CloudRecordFetchRequest(modelID: modelID, limit: 1)
        )

        let middleID = try CloudRecordIdentifier(recordName: "task-b", zone: zone)
        _ = try await client.modify(
            saving: [
                CloudRecordMutation(
                    id: middleID,
                    modelID: modelID,
                    values: [title: .string("b")],
                    policy: .insert
                )
            ],
            deleting: [],
            atomic: true
        )
        let afterInsert = try await client.fetch(
            CloudRecordFetchRequest(modelID: modelID)
        )
        #expect(afterInsert.snapshots.map(\.id.recordName) == ["task-a", "task-b", "task-c"])

        _ = try await client.modify(saving: [], deleting: [firstID], atomic: false)
        let afterDelete = try await client.fetch(
            CloudRecordFetchRequest(modelID: modelID)
        )
        #expect(afterDelete.snapshots.map(\.id.recordName) == ["task-b", "task-c"])
    }

    @Test
    func paginationOrdersRecordsByZoneBeforeRecordName() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let alpha = try CloudZoneIdentifier("Alpha")
        let beta = try CloudZoneIdentifier("Beta")
        let alphaID = try CloudRecordIdentifier(recordName: "zzz", zone: alpha)
        let betaID = try CloudRecordIdentifier(recordName: "aaa", zone: beta)
        let title = try CloudFieldIdentifier("title")
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(
            initial: [
                CloudRecordSnapshot(
                    id: betaID,
                    modelID: modelID,
                    changeTag: "c1",
                    fields: [title: .string("beta")]
                ),
                CloudRecordSnapshot(
                    id: alphaID,
                    modelID: modelID,
                    changeTag: "c2",
                    fields: [title: .string("alpha")]
                )
            ]
        )

        let page = try await client.fetch(CloudRecordFetchRequest(modelID: modelID))
        #expect(page.snapshots.map(\.id) == [alphaID, betaID])
    }

    @Test
    func policiesProduceConflictsAndNonAtomicFailuresWithoutHidingSuccesses() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let zone = try CloudZoneIdentifier("private")
        let title = try CloudFieldIdentifier("title")
        let existingID = try CloudRecordIdentifier(recordName: "task-1", zone: zone)
        let insertedID = try CloudRecordIdentifier(recordName: "task-2", zone: zone)
        let missingID = try CloudRecordIdentifier(recordName: "missing", zone: zone)
        let initial = try CloudRecordSnapshot(
            id: existingID,
            modelID: modelID,
            changeTag: "c10",
            fields: [title: .string("old")]
        )
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [initial])

        let result = try await client.modify(
            saving: [
                CloudRecordMutation(
                    id: existingID,
                    modelID: modelID,
                    values: [title: .string("stale")],
                    policy: .update(expectedChangeTag: "c9")
                ),
                CloudRecordMutation(
                    id: insertedID,
                    modelID: modelID,
                    values: [title: .string("new")],
                    policy: .insert
                )
            ],
            deleting: [missingID],
            atomic: false
        )

        #expect(result.saved.map(\.id) == [insertedID])
        #expect(result.deleted.isEmpty)
        #expect(result.failures.count == 2)
        #expect(result.failures.contains {
            $0.id == existingID && $0.error == .conflict(
                existingID,
                expectedChangeTag: "c9",
                actualChangeTag: "c10"
            )
        })
        #expect(result.failures.contains { $0.id == missingID && $0.error == .notFound(missingID) })

        let update = try CloudRecordMutation(
            id: existingID,
            modelID: modelID,
            values: [title: .string("fresh")],
            policy: .update(expectedChangeTag: "c10")
        )
        let updateResult = try await client.modify(saving: [update], deleting: [], atomic: true)
        #expect(updateResult.saved.first?.fields[title] == .string("fresh"))
    }

    @Test
    func atomicFailureLeavesTheStoreAndChangeTagsUntouched() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let zone = try CloudZoneIdentifier("private")
        let title = try CloudFieldIdentifier("title")
        let existingID = try CloudRecordIdentifier(recordName: "task-1", zone: zone)
        let newID = try CloudRecordIdentifier(recordName: "task-2", zone: zone)
        let initial = try CloudRecordSnapshot(
            id: existingID,
            modelID: modelID,
            changeTag: "c1",
            fields: [title: .string("old")]
        )
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: [initial])

        do {
            _ = try await client.modify(
                saving: [
                    CloudRecordMutation(
                        id: newID,
                        modelID: modelID,
                        values: [title: .string("must not persist")],
                        policy: .insert
                    ),
                    CloudRecordMutation(
                        id: existingID,
                        modelID: modelID,
                        values: [title: .string("stale")],
                        policy: .update(expectedChangeTag: "wrong")
                    )
                ],
                deleting: [],
                atomic: true
            )
            Issue.record("The invalid atomic batch must throw")
        } catch let error as CloudModelError {
            #expect(error == .conflict(
                existingID,
                expectedChangeTag: "wrong",
                actualChangeTag: "c1"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let page = try await client.fetch(CloudRecordFetchRequest(modelID: modelID))
        #expect(page.snapshots.map(\.id) == [existingID])
        #expect(page.snapshots.first?.changeTag == "c1")
        #expect(page.snapshots.first?.fields[title] == .string("old"))
    }

    @Test
    func invalidBatchAndForeignCursorAreRejected() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let zone = try CloudZoneIdentifier("private")
        let recordID = try CloudRecordIdentifier(recordName: "task-1", zone: zone)
        let mutation = try CloudRecordMutation(id: recordID, modelID: modelID, policy: .insert)
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()

        do {
            _ = try await client.modify(
                saving: [mutation, mutation],
                deleting: [],
                atomic: false
            )
            Issue.record("Duplicate mutation IDs must be rejected")
        } catch let error as CloudModelError {
            #expect(error == .invalidRequest("a modify batch cannot save the same record twice"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let foreignCursor = try CloudPageCursor("not-an-offset")
        do {
            _ = try await client.fetch(
                CloudRecordFetchRequest(modelID: modelID, cursor: foreignCursor)
            )
            Issue.record("A cursor from another driver must not be accepted")
        } catch let error as CloudModelError {
            #expect(error == .invalidRequest("invalid in-memory page cursor"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
