import CKSwiftData
import Testing

struct RelationshipCompileTests {
    @Test
    func relationshipExpansionReadsAndWritesTypedBackingData() throws {
        let author = RelationshipCompileAuthor()
        let post = RelationshipCompilePost()

        post.author = author
        #expect(post.author === author)

        author.posts = [post]
        #expect(author.posts.count == 1)
        #expect(author.posts.first === post)

        let authorRelationship = try #require(
            RelationshipCompileAuthor.schemaMetadata.first?.metadata as? Schema.Relationship
        )
        let postRelationship = try #require(
            RelationshipCompilePost.schemaMetadata.first?.metadata as? Schema.Relationship
        )
        #expect(authorRelationship.name == "posts")
        #expect(postRelationship.name == "author")
        #expect(authorRelationship.deleteRule == .cascade)
        #expect(authorRelationship.minimumModelCount == 1)
        #expect(authorRelationship.maximumModelCount == 3)
        #expect(authorRelationship.originalName == "old_posts")
        #expect(postRelationship.originalName == "old_author")
        #expect(authorRelationship.isToOneRelationship == false)
        #expect(postRelationship.isToOneRelationship)
    }

    @Test
    func relationshipMetadataBuildsAValidatedTypedSchema() throws {
        let authorSchema = try RelationshipCompileAuthor.cloudModelSchema()
        let postSchema = try RelationshipCompilePost.cloudModelSchema()
        let relationship = try #require(try authorSchema.field(CloudFieldIdentifier("posts")))
        guard case let .relationship(relationship) = relationship else {
            Issue.record("posts must be represented as a relationship field")
            return
        }
        let expectedDestination = try CloudModelIdentifier("RelationshipCompilePost")
        let expectedInverse = try CloudFieldIdentifier("author")
        #expect(relationship.destination == expectedDestination)
        #expect(relationship.inverse == expectedInverse)
        _ = try CloudSchema(models: [
            authorSchema,
            postSchema
        ])
    }

    @MainActor
    @Test
    func fetchedRelationshipReferencesSurviveScalarSave() async throws {
        let zone = try CloudZoneIdentifier("_defaultZone")
        let authorID = try CloudRecordIdentifier(recordName: "author-1", zone: zone)
        let postID = try CloudRecordIdentifier(recordName: "post-1", zone: zone)
        let authorSchema = try RelationshipCompileAuthor.cloudModelSchema()
        let postSchema = try RelationshipCompilePost.cloudModelSchema()
        let schema = try CloudSchema(models: [authorSchema, postSchema])
        let authorField = try CloudFieldIdentifier("author")
        let postsField = try CloudFieldIdentifier("posts")
        let titleField = try CloudFieldIdentifier("title")
        let authorModel = try CloudRecordSnapshot(
            id: authorID,
            modelID: RelationshipCompileAuthor.cloudModelIdentifier(),
            changeTag: "c1",
            fields: [postsField: .referenceArray([postID])]
        )
        let postModel = try CloudRecordSnapshot(
            id: postID,
            modelID: RelationshipCompilePost.cloudModelIdentifier(),
            changeTag: "c2",
            fields: [
                authorField: .reference(authorID),
                titleField: .string("before")
            ]
        )
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(
            initial: [authorModel, postModel]
        )
        let configuration = try CloudStoreConfiguration(
            containerIdentifier: CloudContainerIdentifier("iCloud.example.Relationships"),
            location: .privateDatabase(.default)
        )
        let container = try CloudModelContainer(
            schema: schema,
            configuration: configuration,
            client: client
        )

        let page = try await container.mainContext.fetch(
            CloudFetchDescriptor<RelationshipCompilePost>(limit: 10)
        )
        let post = try #require(page.models.first)
        post.title = "after"
        _ = try await container.mainContext.save()

        let snapshot = try container.mainContext.snapshot(for: post)
        let saved = try #require(snapshot)
        #expect(saved.fields[authorField] == .reference(authorID))
        #expect(saved.fields[titleField] == .string("after"))
    }

    @MainActor
    @Test
    func newRelationshipsUseTheContainerZone() async throws {
        let zone = try CloudZoneIdentifier("CustomData")
        let schema = try CloudSchema(models: [
            RelationshipCompileAuthor.cloudModelSchema(),
            RelationshipCompilePost.cloudModelSchema()
        ])
        let configuration = try CloudStoreConfiguration(
            containerIdentifier: CloudContainerIdentifier("iCloud.example.Relationships"),
            location: .privateDatabase(.custom(zone))
        )
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        let container = try CloudModelContainer(
            schema: schema,
            configuration: configuration,
            client: client
        )
        let author = RelationshipCompileAuthor()
        let post = RelationshipCompilePost()
        post.title = "child"
        post.author = author

        try container.mainContext.insert(author)
        try container.mainContext.insert(post)
        let result = try await container.mainContext.save()
        #expect(result.failures.isEmpty)

        let authorID = try author.cloudRecordIdentifier(in: zone)
        let postID = try post.cloudRecordIdentifier(in: zone)
        let authorField = try CloudFieldIdentifier("author")
        let postsField = try CloudFieldIdentifier("posts")
        #expect(result.saved.first(where: { $0.id == postID })?.fields[authorField] == .reference(authorID))
        #expect(result.saved.first(where: { $0.id == authorID })?.fields[postsField] == .referenceArray([postID]))
    }
}
