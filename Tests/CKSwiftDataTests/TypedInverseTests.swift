import CKSwiftData
import Foundation
import Testing

struct TypedInverseTests {
    private func inverse(
        of field: String,
        in schema: CloudModelSchema
    ) throws -> String? {
        guard case let .relationship(relationship)? = try schema.field(CloudFieldIdentifier(field)) else {
            return nil
        }
        return relationship.inverse?.rawValue
    }

    @Test
    func keyPathOnTheToManySideInfersTheToOneSide() throws {
        let schema = try CloudSchema(models: [
            TypedInverseProject.cloudModelSchema(),
            TypedInverseTask.cloudModelSchema()
        ])
        let project = try #require(schema.model(TypedInverseProject.cloudModelIdentifier()))
        let task = try #require(schema.model(TypedInverseTask.cloudModelIdentifier()))

        #expect(try inverse(of: "tasks", in: project) == "project")
        #expect(try inverse(of: "project", in: task) == "tasks")
    }

    @Test
    func keyPathOnTheToOneSideInfersTheToManySide() throws {
        let schema = try CloudSchema(models: [
            TypedInverseOwner.cloudModelSchema(),
            TypedInverseNote.cloudModelSchema()
        ])
        let owner = try #require(schema.model(TypedInverseOwner.cloudModelIdentifier()))
        let note = try #require(schema.model(TypedInverseNote.cloudModelIdentifier()))

        #expect(try inverse(of: "notes", in: owner) == "owner")
        #expect(try inverse(of: "owner", in: note) == "notes")
    }

    @Test
    func selfReferencingModelNeedsTheKeyPathOnlyOnce() throws {
        let schema = try CloudSchema(models: [TypedInverseFolder.cloudModelSchema()])
        let folder = try #require(schema.model(TypedInverseFolder.cloudModelIdentifier()))

        #expect(try inverse(of: "children", in: folder) == "parent")
        #expect(try inverse(of: "parent", in: folder) == "children")
    }

    @Test
    func inverseNameStillWorksOnBothSides() throws {
        let schema = try CloudSchema(models: [
            RelationshipCompileAuthor.cloudModelSchema(),
            RelationshipCompilePost.cloudModelSchema()
        ])
        let author = try #require(schema.model(RelationshipCompileAuthor.cloudModelIdentifier()))
        let post = try #require(schema.model(RelationshipCompilePost.cloudModelIdentifier()))

        #expect(try inverse(of: "posts", in: author) == "author")
        #expect(try inverse(of: "author", in: post) == "posts")
    }

    @Test
    func keyPathInverseKeepsTheRuntimeMetadataCacheAndUsesRecordTypes() throws {
        #expect(TypedInverseStableOwner.cloudModelRuntimeMetadataIsStable)
        #expect(TypedInverseStableItem.cloudModelRuntimeMetadataIsStable)

        let schema = try CloudSchema(models: [
            TypedInverseStableOwner.cloudModelSchema(),
            TypedInverseStableItem.cloudModelSchema()
        ])
        let owner = try #require(schema.model(CloudModelIdentifier("StableOwner")))
        let item = try #require(schema.model(CloudModelIdentifier("StableItem")))

        #expect(try inverse(of: "items", in: owner) == "owner")
        #expect(try inverse(of: "owner", in: item) == "items")
    }

    @MainActor
    @Test
    func modelsWithAnInferredInverseSaveAndFetch() async throws {
        let schema = try CloudSchema(models: [
            TypedInverseProject.cloudModelSchema(),
            TypedInverseTask.cloudModelSchema()
        ])
        let configuration = try CloudStoreConfiguration(
            containerIdentifier: CloudContainerIdentifier("iCloud.example.TypedInverse"),
            location: .privateDatabase(.default)
        )
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        let container = try CloudModelContainer(
            schema: schema,
            configuration: configuration,
            client: client
        )
        let project = TypedInverseProject()
        project.name = "Roadmap"
        let task = TypedInverseTask()
        task.title = "Ship"
        task.project = project
        try container.mainContext.insert(project)
        try container.mainContext.insert(task)
        let result = try await container.mainContext.save()
        #expect(result.failures.isEmpty)

        let page = try await container.mainContext.fetch(
            CloudFetchDescriptor<TypedInverseTask>(limit: 10)
        )
        #expect(page.models.map(\.title) == ["Ship"])
    }
}
