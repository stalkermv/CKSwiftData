import CKSwiftData
import Foundation
import Testing

struct CloudRecordBoundaryTests {
    @Test
    func snapshotsAndMutationsRoundTripWithoutLosingTypedValues() throws {
        let modelID = try CloudModelIdentifier("Task")
        let recordID = try CloudRecordIdentifier(
            recordName: "task-1",
            zone: CloudZoneIdentifier("private")
        )
        let title = try CloudFieldIdentifier("title")
        let completed = try CloudFieldIdentifier("completed")
        let tags = try CloudFieldIdentifier("tags")
        let author = try CloudFieldIdentifier("author")

        let snapshot = try CloudRecordSnapshot(
            id: recordID,
            modelID: modelID,
            changeTag: "  c1  ",
            fields: [
                title: .string("Write tests"),
                completed: .bool(false),
                tags: .stringArray(["cloud", "swift"]),
                author: .reference(recordID)
            ]
        )
        let mutation = try CloudRecordMutation(
            id: recordID,
            modelID: modelID,
            values: [title: .string("Write more tests")],
            removedFields: [completed],
            policy: .update(expectedChangeTag: "  c1  ")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let snapshotData = try encoder.encode(snapshot)
        let mutationData = try encoder.encode(mutation)
        let decodedSnapshot = try JSONDecoder().decode(CloudRecordSnapshot.self, from: snapshotData)
        let decodedMutation = try JSONDecoder().decode(CloudRecordMutation.self, from: mutationData)

        #expect(decodedSnapshot == snapshot)
        #expect(decodedSnapshot.changeTag == "c1")
        #expect(decodedMutation == mutation)
        #expect(decodedMutation.policy == .update(expectedChangeTag: "c1"))
    }

    @Test
    func fetchRequestsValidateLimitsAndEncodeSortedFieldSelection() throws {
        let modelID = try CloudModelIdentifier("Task")
        let title = try CloudFieldIdentifier("title")
        let completed = try CloudFieldIdentifier("completed")
        let request = try CloudRecordFetchRequest(
            modelID: modelID,
            limit: 2,
            cursor: CloudPageCursor("opaque-token"),
            desiredFields: [completed, title]
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CloudRecordFetchRequest.self, from: data)

        #expect(decoded == request)
        #expect(decoded.desiredFields == [completed, title])

        do {
            _ = try CloudRecordFetchRequest(modelID: modelID, limit: 0)
            Issue.record("A non-positive fetch limit must be rejected")
        } catch let error as CloudRecordBoundaryError {
            #expect(error == .invalidLimit(0))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func mutationRejectsAmbiguousFieldOperationsAndEmptyTags() throws {
        let modelID = try CloudModelIdentifier("Task")
        let recordID = try CloudRecordIdentifier(
            recordName: "task-1",
            zone: CloudZoneIdentifier("private")
        )
        let title = try CloudFieldIdentifier("title")

        do {
            _ = try CloudRecordMutation(
                id: recordID,
                modelID: modelID,
                values: [title: .string("same field")],
                removedFields: [title]
            )
            Issue.record("A field cannot be both written and removed")
        } catch let error as CloudRecordBoundaryError {
            #expect(error == .fieldIsBothSetAndRemoved(title))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            _ = try CloudRecordMutation(
                id: recordID,
                modelID: modelID,
                policy: .update(expectedChangeTag: "   ")
            )
            Issue.record("An update must carry a non-empty change tag")
        } catch let error as CloudRecordBoundaryError {
            #expect(error == .emptyChangeTag)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func modifyResultPreservesPartialFailuresExplicitly() throws {
        let modelID = try CloudModelIdentifier("Task")
        let successfulID = try CloudRecordIdentifier(
            recordName: "task-1",
            zone: CloudZoneIdentifier("private")
        )
        let failedID = try CloudRecordIdentifier(
            recordName: "task-2",
            zone: CloudZoneIdentifier("private")
        )
        let snapshot = try CloudRecordSnapshot(id: successfulID, modelID: modelID)
        let result = try CloudModifyResult(
            saved: [snapshot],
            failures: [
                CloudRecordFailure(
                    id: failedID,
                    operation: .save,
                    error: .conflict(
                        failedID,
                        expectedChangeTag: "c1",
                        actualChangeTag: "c2"
                    )
                )
            ]
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CloudModifyResult.self, from: data)

        #expect(decoded == result)
        #expect(decoded.isPartial)
        #expect(decoded.saved == [snapshot])
        #expect(decoded.failures.first?.error == .conflict(
            failedID,
            expectedChangeTag: "c1",
            actualChangeTag: "c2"
        ))
    }

    @Test
    func decodedPagesAndModifyResultsRejectDuplicateRecordIDs() throws {
        let modelID = try CloudModelIdentifier("Task")
        let recordID = try CloudRecordIdentifier(
            recordName: "task-duplicate",
            zone: CloudZoneIdentifier("private")
        )
        let snapshot = try CloudRecordSnapshot(id: recordID, modelID: modelID)

        struct PagePayload: Encodable {
            let snapshots: [CloudRecordSnapshot]
            let nextCursor: CloudPageCursor?
            let failures: [CloudRecordFailure]
        }
        let pageData = try JSONEncoder().encode(PagePayload(
            snapshots: [snapshot, snapshot],
            nextCursor: nil,
            failures: []
        ))
        do {
            _ = try JSONDecoder().decode(CloudRecordPage.self, from: pageData)
            Issue.record("Decoded pages must reject duplicate record IDs")
        } catch let error as CloudRecordBoundaryError {
            #expect(error == .duplicateRecordIdentifier(recordID))
        } catch {
            Issue.record("Unexpected page error: \(error)")
        }

        struct ResultPayload: Encodable {
            let saved: [CloudRecordSnapshot]
            let deleted: [CloudRecordIdentifier]
            let failures: [CloudRecordFailure]
        }
        let resultData = try JSONEncoder().encode(ResultPayload(
            saved: [snapshot, snapshot],
            deleted: [],
            failures: []
        ))
        do {
            _ = try JSONDecoder().decode(CloudModifyResult.self, from: resultData)
            Issue.record("Decoded modify results must reject duplicate saved IDs")
        } catch let error as CloudRecordBoundaryError {
            #expect(error == .duplicateRecordIdentifier(recordID))
        } catch {
            Issue.record("Unexpected result error: \(error)")
        }
    }

    @Test
    func pagesAndModifyResultsRejectAmbiguousOutcomeIDs() throws {
        let modelID = try CloudModelIdentifier("Task")
        let zone = try CloudZoneIdentifier("private")
        let recordID = try CloudRecordIdentifier(recordName: "task-ambiguous", zone: zone)
        let snapshot = try CloudRecordSnapshot(id: recordID, modelID: modelID)
        let failure = CloudRecordFailure(
            id: recordID,
            operation: .fetch,
            error: .partialFailure
        )

        do {
            _ = try CloudRecordPage(snapshots: [snapshot], failures: [failure])
            Issue.record("A page cannot report one record as both snapshot and failure")
        } catch let error as CloudRecordBoundaryError {
            #expect(error == .duplicateRecordIdentifier(recordID))
        } catch {
            Issue.record("Unexpected page error: \(error)")
        }

        do {
            _ = try CloudRecordPage(snapshots: [], failures: [failure, failure])
            Issue.record("A page cannot contain duplicate failures for one record")
        } catch let error as CloudRecordBoundaryError {
            #expect(error == .duplicateRecordIdentifier(recordID))
        } catch {
            Issue.record("Unexpected page failure error: \(error)")
        }

        do {
            _ = try CloudModifyResult(saved: [snapshot], deleted: [recordID])
            Issue.record("A modify result cannot report one record as saved and deleted")
        } catch let error as CloudRecordBoundaryError {
            #expect(error == .duplicateRecordIdentifier(recordID))
        } catch {
            Issue.record("Unexpected saved/deleted error: \(error)")
        }

        do {
            _ = try CloudModifyResult(saved: [snapshot], failures: [failure])
            Issue.record("A modify result cannot report one record as saved and failed")
        } catch let error as CloudRecordBoundaryError {
            #expect(error == .duplicateRecordIdentifier(recordID))
        } catch {
            Issue.record("Unexpected saved/failure error: \(error)")
        }

        do {
            _ = try CloudModifyResult(failures: [failure, failure])
            Issue.record("A modify result cannot contain duplicate failures for one record")
        } catch let error as CloudRecordBoundaryError {
            #expect(error == .duplicateRecordIdentifier(recordID))
        } catch {
            Issue.record("Unexpected failure error: \(error)")
        }
    }
}
