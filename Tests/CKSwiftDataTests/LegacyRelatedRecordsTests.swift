@testable import CKSwiftData
import CloudKit
import Testing

struct LegacyRelatedRecordsTests {
    private func backing<Model: CloudKitModel>(of model: Model) throws -> CKBackingData<Model> {
        try #require(model.persistentBackingData as? CKBackingData<Model>)
    }

    private func reference(to recordID: CKRecord.ID) -> CKRecord.Reference {
        CKRecord.Reference(recordID: recordID, action: .none)
    }

    @Test
    func saveIncludesEveryMemberOfAToManyRelationship() throws {
        let author = RelationshipCompileAuthor()
        let first = RelationshipCompilePost()
        let second = RelationshipCompilePost()
        author.posts = [first, second]
        let authorBacking = try backing(of: author)

        #expect(Set(authorBacking.relatedRecordsToSave.map(\.recordID)) == [first.recordID, second.recordID])
    }

    @Test
    func saveIncludesAToOneRelationship() throws {
        let post = RelationshipCompilePost()
        let author = RelationshipCompileAuthor()
        post.author = author
        let postBacking = try backing(of: post)

        // The previous save loop cast each entry to this existential, which
        // never matches the stored backing object of a concrete model type.
        #expect((postBacking.relatedBackingData["author"] as? any BackingData<any CloudKitModel>) == nil)
        #expect(postBacking.relatedRecordsToSave.map(\.recordID) == [author.recordID])
    }

    @Test
    func saveIncludesPreloadedRecordsAndAdoptsServerCopies() throws {
        let post = RelationshipCompilePost()
        let postBacking = try backing(of: post)
        let author = CKRecord(recordType: RelationshipCompileAuthor.recordType)
        postBacking.record["author"] = reference(to: author.recordID)
        postBacking.relatedBackingData["author"] = author

        #expect(postBacking.relatedRecordsToSave.map(\.recordID) == [author.recordID])

        let serverCopy = CKRecord(recordType: RelationshipCompileAuthor.recordType, recordID: author.recordID)
        postBacking.adoptSavedRelatedRecords([author.recordID: serverCopy])
        #expect((postBacking.relatedBackingData["author"] as? CKRecord) === serverCopy)
    }

    @Test
    func adoptingServerCopiesUpdatesRelatedBackingObjects() throws {
        let author = RelationshipCompileAuthor()
        let post = RelationshipCompilePost()
        author.posts = [post]
        let authorBacking = try backing(of: author)
        let serverCopy = CKRecord(recordType: RelationshipCompilePost.recordType, recordID: post.recordID)

        authorBacking.adoptSavedRelatedRecords([post.recordID: serverCopy])

        #expect(try backing(of: post).record === serverCopy)
    }

    @Test
    func replacingAPreloadedToOneRelationshipRemovesTheOldInverse() throws {
        let post = RelationshipCompilePost()
        let postBacking = try backing(of: post)
        let preloadedAuthor = CKRecord(recordType: RelationshipCompileAuthor.recordType)
        preloadedAuthor["posts"] = [reference(to: post.recordID)]
        postBacking.record["author"] = reference(to: preloadedAuthor.recordID)
        postBacking.relatedBackingData["author"] = preloadedAuthor

        post.author = RelationshipCompileAuthor()

        let remaining = preloadedAuthor["posts"] as? [CKRecord.Reference] ?? []
        #expect(remaining.contains { $0.recordID == post.recordID } == false)
    }

    @Test
    func replacingAPreloadedToManyRelationshipRemovesTheOldInverse() throws {
        let author = RelationshipCompileAuthor()
        let authorBacking = try backing(of: author)
        let preloadedPost = CKRecord(recordType: RelationshipCompilePost.recordType)
        preloadedPost["author"] = reference(to: author.recordID)
        authorBacking.record["posts"] = [reference(to: preloadedPost.recordID)]
        authorBacking.relatedBackingData["posts"] = [preloadedPost.recordID.recordName: preloadedPost]

        author.posts = []

        #expect(preloadedPost["author"] == nil)
    }
}
