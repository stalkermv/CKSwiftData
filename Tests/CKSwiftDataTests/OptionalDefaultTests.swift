import CKSwiftData
import Foundation
import Testing

@CloudModel(recordType: "OptionalWithDefault")
final class OptionalWithDefaultModel {
    var nickname: String? = "nick"
}

struct OptionalDefaultTests {
    @Test
    func anOptionalPropertyWithADefaultIsAnOptionalField() throws {
        let schema = try OptionalWithDefaultModel.cloudModelSchema()
        let field = try #require(schema.field(CloudFieldIdentifier("nickname")))
        guard case let .attribute(attribute) = field else {
            Issue.record("nickname must be an attribute")
            return
        }

        #expect(attribute.optionality == .optional)
    }

    @MainActor
    @Test
    func anOptionalPropertyWithADefaultCanBeClearedBeforeInsert() async throws {
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [OptionalWithDefaultModel.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.OptionalDefault"),
                location: .privateDatabase(.default)
            ),
            client: CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        )
        let model = OptionalWithDefaultModel()
        model.nickname = nil
        try container.mainContext.insert(model)

        let result = try await container.mainContext.save()

        #expect(result.failures.isEmpty)
        #expect(result.saved.count == 1)
    }
}
