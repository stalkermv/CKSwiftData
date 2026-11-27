import CKSwiftData
import Foundation
import Testing

struct CloudRetryTests {
    @Test
    func retryPolicyBoundsAttemptsAndHonorsServerDelay() throws {
        let policy = try CloudRetryPolicy(
            maxAttempts: 4,
            initialDelay: 1,
            maximumDelay: 5,
            multiplier: 2
        )
        #expect(policy.delay(beforeAttempt: 1) == 1)
        #expect(policy.delay(beforeAttempt: 3) == 4)
        #expect(policy.delay(beforeAttempt: 1, serverRetryAfter: 3) == 3)

        do {
            _ = try CloudRetryPolicy(maxAttempts: 0)
            Issue.record("zero attempts must be rejected")
        } catch let error as CloudRetryPolicyError {
            #expect(error == .invalidAttemptCount(0))
        }
    }

    @Test
    func storeRetriesTransientFetchesWithoutRetryingConflicts() async throws {
        let modelID = try CloudModelIdentifier("Task")
        let schema = try CloudSchema(models: [
            CloudModelSchema(id: modelID, recordType: modelID, fields: [])
        ])
        let base = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        let client = CKSwiftDataTesting.ScriptedCloudDatabaseClient(
            base: base,
            fetchFailures: [
                .retryable("temporary-1", retryAfter: nil),
                .retryable("temporary-2", retryAfter: nil)
            ]
        )
        let store = try CloudKitRecordStore(
            schema: schema,
            configuration: configuration(),
            client: client
        )
        let page = try await store.fetch(
            CloudRecordFetchRequest(modelID: modelID),
            retryPolicy: .immediate
        )
        #expect(page.snapshots.isEmpty)

        let conflictClient = try CKSwiftDataTesting.ScriptedCloudDatabaseClient(
            base: base,
            fetchFailures: [.conflict(
                CloudRecordIdentifier(
                    recordName: "task-1",
                    zone: CloudZoneIdentifier("default")
                ),
                expectedChangeTag: "c1",
                actualChangeTag: "c2"
            )]
        )
        let conflictStore = try CloudKitRecordStore(
            schema: schema,
            configuration: configuration(),
            client: conflictClient
        )
        do {
            _ = try await conflictStore.fetch(
                CloudRecordFetchRequest(modelID: modelID),
                retryPolicy: .immediate
            )
            Issue.record("conflicts must not be retried as transient failures")
        } catch let error as CloudModelError {
            #expect(error.isRetryable == false)
        }
    }

    private func configuration() throws -> CloudStoreConfiguration {
        try CloudStoreConfiguration(
            containerIdentifier: CloudContainerIdentifier("iCloud.example.Tests"),
            location: .privateDatabase(.default)
        )
    }
}
