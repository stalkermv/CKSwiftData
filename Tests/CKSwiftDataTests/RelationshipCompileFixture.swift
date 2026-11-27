import CKSwiftData

@CloudModel
final class RelationshipCompileAuthor {
    @Relationship(deleteRule: .cascade, minimum: 1, maximum: 3, originalName: "old_posts", inverseName: "author")
    var posts: [RelationshipCompilePost] = []
}

@CloudModel
final class RelationshipCompilePost {
    @Relationship(originalName: "old_author", inverseName: "posts")
    var author: RelationshipCompileAuthor?
    var title: String = ""
}
