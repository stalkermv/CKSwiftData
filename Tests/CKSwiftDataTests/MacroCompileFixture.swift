import CKSwiftData

@CloudModel(recordType: "ExplicitTask", schemaVersion: 3)
final class MacroCompileFixture {
    @Attribute(.unique, originalName: "legacy_title")
    var title: String = ""
    var note: String?
}

@CloudModel(recordType: "SecondaryTask", schemaVersion: 1)
final class SecondaryCompileFixture {
    var title: String = ""
}
