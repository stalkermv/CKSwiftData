import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@testable import CKSwiftDataMacros

struct ModelMacroMemberValidationTests {
    private struct MemberExpansion {
        let attributes: [String]
        let diagnostics: [String]
        let metadata: String
    }

    private func expand(member: String) throws -> MemberExpansion {
        let source = """
        final class Project {
            \(member)
        }
        """
        let file = Parser.parse(source: source)
        let declaration = try #require(file.statements.first?.item.as(ClassDeclSyntax.self))
        let variable = try #require(declaration.memberBlock.members.first?.decl.as(VariableDeclSyntax.self))
        let modelAttribute = AttributeSyntax(attributeName: IdentifierTypeSyntax(name: .identifier("CloudModel")))
        let context = BasicMacroExpansionContext()
        let attributes = try ModelMacro.expansion(
            of: modelAttribute,
            attachedTo: declaration,
            providingAttributesFor: variable,
            in: context
        )
        let metadata = ModelMacro.schemaMetadata(
            for: declaration.name,
            with: [variable],
            in: BasicMacroExpansionContext()
        )
        return MemberExpansion(
            attributes: attributes.map(\.trimmedDescription),
            diagnostics: context.diagnostics.map(\.message),
            metadata: metadata.description
        )
    }

    @Test
    func storedPropertyIsPersisted() throws {
        let expansion = try expand(member: #"var name: String = """#)
        #expect(expansion.attributes == ["@PersistedProperty"])
        #expect(expansion.diagnostics.isEmpty)
        #expect(expansion.metadata.contains(#"name: "name""#))
    }

    @Test(arguments: [
        ("static var shared: String = \"\"", "static or class"),
        ("class var kind: String { \"\" }", "static or class"),
        ("var displayName: String { \"\" }", "computed"),
        ("var displayName: String { get { \"\" } set { } }", "computed"),
        ("var name: String = \"\" { didSet { } }", "accessors or observers"),
        ("lazy var cache: String = \"\"", "lazy"),
        ("weak var delegate: AnyObject?", "weak or unowned"),
        ("let identifier: String = \"\"", "'var'"),
        ("var first: String = \"\", second: String = \"\"", "one property per declaration"),
        ("var count = 0", "explicit type")
    ])
    func unsupportedMemberIsDiagnosedAndNotPersisted(member: String, reason: String) throws {
        let expansion = try expand(member: member)
        #expect(expansion.attributes.isEmpty)
        #expect(expansion.diagnostics.count == 1)
        #expect(expansion.diagnostics.first?.contains(reason) == true)
        #expect(expansion.metadata.contains("PropertyMetadata(") == false)
    }

    @Test(arguments: [
        "@Transient static var shared: String = \"\"",
        "@Transient var displayName: String { \"\" }",
        "@Transient lazy var cache: [String] = []",
    ])
    func transientMemberIsNeitherDiagnosedNorPersisted(member: String) throws {
        let expansion = try expand(member: member)
        #expect(expansion.attributes.isEmpty)
        #expect(expansion.diagnostics.isEmpty)
        #expect(expansion.metadata.contains("PropertyMetadata(") == false)
    }
}
