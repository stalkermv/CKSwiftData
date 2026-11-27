import CKSwiftData
import Foundation
import Testing

@CloudModel(recordType: "Proj", schemaVersion: 1)
final class DeclaredRecordTypeProject {
    var name: String = ""
    @Relationship(deleteRule: .cascade, inverseName: "project")
    var items: [DeclaredRecordTypeItem] = []
}

@CloudModel(recordType: "Itm", schemaVersion: 3)
final class DeclaredRecordTypeItem {
    var title: String = ""
    @Relationship(inverseName: "items") var project: DeclaredRecordTypeProject?
}

@CloudModel
final class DeclaredRecordTypeDefault {
    var title: String = ""
}

@CloudModel(schemaVersion: 2)
final class DeclaredRecordTypeVersioned {
    var title: String = ""
}

struct DeclaredRecordTypeTests {
    @Test
    func declaredRecordTypeIsUsedByTheRuntimeMetadata() throws {
        #expect(DeclaredRecordTypeProject.recordType == "Proj")
        #expect(DeclaredRecordTypeProject.cloudRecordType == "Proj")
        #expect(try DeclaredRecordTypeProject.cloudModelIdentifier().rawValue == "Proj")

        let schema = try DeclaredRecordTypeItem.cloudModelSchema()
        #expect(schema.id.rawValue == "Itm")
        #expect(schema.recordType.rawValue == "Itm")
        #expect(schema.version == 3)
    }

    @Test
    func relationshipsPointAtTheDeclaredRecordTypeOfTheirDestination() throws {
        let schema = try CloudSchema(models: [
            DeclaredRecordTypeProject.cloudModelSchema(),
            DeclaredRecordTypeItem.cloudModelSchema()
        ])
        let project = try #require(schema.model(CloudModelIdentifier("Proj")))
        let field = try #require(project.field(CloudFieldIdentifier("items")))
        guard case let .relationship(relationship) = field else {
            Issue.record("items must be a relationship")
            return
        }
        #expect(relationship.destination.rawValue == "Itm")
        #expect(relationship.inverse?.rawValue == "project")
    }

    @MainActor
    @Test
    func savedRecordsUseTheDeclaredRecordType() async throws {
        let schema = try CloudSchema(models: [
            DeclaredRecordTypeProject.cloudModelSchema(),
            DeclaredRecordTypeItem.cloudModelSchema()
        ])
        let configuration = try CloudStoreConfiguration(
            containerIdentifier: CloudContainerIdentifier("iCloud.example.RecordTypes"),
            location: .privateDatabase(.default)
        )
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        let container = try CloudModelContainer(
            schema: schema,
            configuration: configuration,
            client: client
        )
        let project = DeclaredRecordTypeProject()
        project.name = "Roadmap"
        let item = DeclaredRecordTypeItem()
        item.title = "Ship"
        item.project = project
        try container.mainContext.insert(project)
        try container.mainContext.insert(item)
        let result = try await container.mainContext.save()
        #expect(result.failures.isEmpty)

        let projects = try await client.fetch(
            CloudRecordFetchRequest(modelID: CloudModelIdentifier("Proj"), limit: 10)
        )
        let items = try await client.fetch(
            CloudRecordFetchRequest(modelID: CloudModelIdentifier("Itm"), limit: 10)
        )
        #expect(projects.snapshots.count == 1)
        #expect(items.snapshots.count == 1)

        let fetched = try await container.mainContext.fetch(
            CloudFetchDescriptor<DeclaredRecordTypeProject>(limit: 10)
        )
        #expect(fetched.models.map(\.name) == ["Roadmap"])
    }

    @Test
    func omittedRecordTypeFallsBackToTheClassName() throws {
        #expect(DeclaredRecordTypeDefault.cloudRecordType == "DeclaredRecordTypeDefault")
        #expect(try DeclaredRecordTypeDefault.cloudModelSchema().recordType.rawValue == "DeclaredRecordTypeDefault")
        #expect(DeclaredRecordTypeDefault.cloudSchemaVersion == 1)

        #expect(DeclaredRecordTypeVersioned.cloudRecordType == "DeclaredRecordTypeVersioned")
        #expect(DeclaredRecordTypeVersioned.cloudSchemaVersion == 2)
        #expect(try DeclaredRecordTypeVersioned.cloudModelSchema().version == 2)
    }
}
