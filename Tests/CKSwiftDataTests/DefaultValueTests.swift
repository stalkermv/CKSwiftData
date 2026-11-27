import CKSwiftData
import Foundation
import Testing

private let defaultEpoch = Date(timeIntervalSince1970: 1_000)

@CloudModel(recordType: "DefaultValues")
final class DefaultValueModel {
    var title: String = "untitled"
    var count: Int = 3
    var tags: [String] = ["a", "b"]
    var emptyTags: [String] = []
    var created: Date = defaultEpoch
    var note: String?
    var nickname: String? = "nick"
}

@CloudModel(recordType: "ImplicitDefaults")
final class ImplicitDefaultModel {
    var text: String = ""
    var lastUpdated: Date = .now
    var epoch: Date = .init(timeIntervalSince1970: 5)
}

@CloudModel(recordType: "RequiredWithoutDefault")
final class RequiredWithoutDefaultModel {
    var name: String
    var detail: String = "detail"
}

struct DefaultValueTests {
    @MainActor
    private func makeContainer() throws -> (
        CloudModelContainer,
        CKSwiftDataTesting.InMemoryCloudDatabaseClient
    ) {
        let schema = try CloudSchema(models: [
            DefaultValueModel.cloudModelSchema(),
            ImplicitDefaultModel.cloudModelSchema(),
            RequiredWithoutDefaultModel.cloudModelSchema()
        ])
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        let container = try CloudModelContainer(
            schema: schema,
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.Defaults"),
                location: .privateDatabase(.default)
            ),
            client: client
        )
        return (container, client)
    }

    private func storedSnapshot(
        in client: CKSwiftDataTesting.InMemoryCloudDatabaseClient,
        model: CloudModelIdentifier
    ) async throws -> CloudRecordSnapshot {
        let page = try await client.fetch(CloudRecordFetchRequest(modelID: model, limit: 10))
        return try #require(page.snapshots.first)
    }

    private func field(_ name: String, in snapshot: CloudRecordSnapshot) throws -> CloudRecordValue? {
        try snapshot.fields[CloudFieldIdentifier(name)]
    }

    @MainActor
    @Test
    func defaultValuesAreWrittenWhenAModelIsInserted() async throws {
        let (container, client) = try makeContainer()
        let model = DefaultValueModel()
        try container.mainContext.insert(model)
        let result = try await container.mainContext.save()
        #expect(result.failures.isEmpty)

        let snapshot = try await storedSnapshot(in: client, model: DefaultValueModel.cloudModelIdentifier())
        #expect(try field("title", in: snapshot) == .string("untitled"))
        #expect(try field("count", in: snapshot) == .int64(3))
        #expect(try field("tags", in: snapshot) == .stringArray(["a", "b"]))
        #expect(try field("emptyTags", in: snapshot) == .stringArray([]))
        #expect(try field("created", in: snapshot) == .date(Date(timeIntervalSince1970: 1_000)))
        #expect(try field("nickname", in: snapshot) == .string("nick"))
        #expect(try field("note", in: snapshot) == nil)
    }

    @MainActor
    @Test
    func anAssignedValueOverridesTheDefault() async throws {
        let (container, client) = try makeContainer()
        let model = DefaultValueModel()
        model.title = "assigned"
        model.tags = ["x"]
        model.nickname = nil
        try container.mainContext.insert(model)
        _ = try await container.mainContext.save()

        let snapshot = try await storedSnapshot(in: client, model: DefaultValueModel.cloudModelIdentifier())
        #expect(try field("title", in: snapshot) == .string("assigned"))
        #expect(try field("tags", in: snapshot) == .stringArray(["x"]))
        #expect(try field("nickname", in: snapshot) == nil)
        #expect(try field("count", in: snapshot) == .int64(3))
    }

    @MainActor
    @Test
    func aRequiredFieldWithoutADefaultStaysRequired() async throws {
        let (container, _) = try makeContainer()
        let model = RequiredWithoutDefaultModel()
        try container.mainContext.insert(model)

        do {
            _ = try await container.mainContext.save()
            Issue.record("A required field without a default must be rejected")
        } catch let error as CloudModelError {
            #expect(error == .invalidRequest("required field name is missing for insert"))
        }
    }

    @MainActor
    @Test
    func implicitMemberDefaultsAreEvaluatedOnceWhenTheModelIsCreated() async throws {
        let (container, client) = try makeContainer()
        let model = ImplicitDefaultModel()
        let created = model.lastUpdated
        try await Task.sleep(for: .milliseconds(30))

        #expect(model.lastUpdated == created)
        #expect(abs(created.timeIntervalSinceNow) < 60)

        try container.mainContext.insert(model)
        _ = try await container.mainContext.save()
        let snapshot = try await storedSnapshot(in: client, model: ImplicitDefaultModel.cloudModelIdentifier())
        #expect(try field("text", in: snapshot) == .string(""))
        #expect(try field("lastUpdated", in: snapshot) == .date(created))
        #expect(try field("epoch", in: snapshot) == .date(Date(timeIntervalSince1970: 5)))

        try await Task.sleep(for: .milliseconds(30))
        #expect(ImplicitDefaultModel().lastUpdated > created)
    }
}
