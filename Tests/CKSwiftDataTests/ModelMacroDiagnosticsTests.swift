import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@testable import CKSwiftDataMacros

struct ModelMacroDiagnosticsTests {
    private struct Expansion {
        let metadata: String
        let diagnostics: [String]
    }

    private func schemaMetadata(forRelationship attribute: String) throws -> Expansion {
        let source = """
        final class Project {
            \(attribute)
            var tasks: [TodoItem] = []
        }
        """
        let file = Parser.parse(source: source)
        let declaration = try #require(
            file.statements.first?.item.as(ClassDeclSyntax.self)
        )
        let properties = declaration.memberBlock.members.compactMap {
            $0.decl.as(VariableDeclSyntax.self)
        }
        let context = BasicMacroExpansionContext()
        let metadata = ModelMacro.schemaMetadata(
            for: declaration.name,
            with: properties,
            in: context
        )
        return Expansion(
            metadata: metadata.description,
            diagnostics: context.diagnostics.map(\.message)
        )
    }

    @Test
    func keyPathAtTheDestinationNamesTheInverse() throws {
        let expansion = try schemaMetadata(
            forRelationship: "@Relationship(inverse: \\TodoItem.project)"
        )

        #expect(expansion.diagnostics.isEmpty)
        #expect(expansion.metadata.contains("inverseName: \"project\""))
    }

    @Test
    func moduleQualifiedRootIsNotSupported() throws {
        let expansion = try schemaMetadata(
            forRelationship: "@Relationship(inverse: \\App.TodoItem.project)"
        )

        #expect(expansion.diagnostics == ["The inverse key path must name exactly one property"])
    }

    @Test
    func keyPathAtAnotherTypeIsRejected() throws {
        let expansion = try schemaMetadata(
            forRelationship: "@Relationship(inverse: \\Other.project)"
        )

        #expect(expansion.diagnostics == [
            "The inverse key path must start at the destination type 'TodoItem'"
        ])
        #expect(expansion.metadata.contains("inverseName: nil"))
    }

    @Test
    func keyPathWithSeveralComponentsIsRejected() throws {
        let expansion = try schemaMetadata(
            forRelationship: "@Relationship(inverse: \\TodoItem.project.name)"
        )

        #expect(expansion.diagnostics == ["The inverse key path must name exactly one property"])
        #expect(expansion.metadata.contains("inverseName: nil"))
    }

    @Test
    func inverseThatIsNotAKeyPathLiteralIsRejected() throws {
        let expansion = try schemaMetadata(
            forRelationship: "@Relationship(inverse: inverseKeyPath)"
        )

        #expect(expansion.diagnostics == [
            "The inverse must be a key path literal such as \\TodoItem.project"
        ])
        #expect(expansion.metadata.contains("inverseName: nil"))
    }

    @Test
    func nilInverseDeclaresNoInverse() throws {
        let expansion = try schemaMetadata(forRelationship: "@Relationship(inverse: nil)")

        #expect(expansion.diagnostics.isEmpty)
        #expect(expansion.metadata.contains("inverseName: nil"))
    }

    @Test
    func inverseNameTakesPrecedenceOverTheKeyPath() throws {
        let expansion = try schemaMetadata(
            forRelationship: "@Relationship(inverse: \\TodoItem.project, inverseName: \"owner\")"
        )

        #expect(expansion.diagnostics.isEmpty)
        #expect(expansion.metadata.contains("inverseName: \"owner\""))
    }
}
