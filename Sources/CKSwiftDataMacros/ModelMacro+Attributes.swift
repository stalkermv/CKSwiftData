import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension ModelMacro {
    public static func expansion(
        of node: SwiftSyntax.AttributeSyntax,
        attachedTo declaration: some SwiftSyntax.DeclGroupSyntax,
        providingAttributesFor member: some SwiftSyntax.DeclSyntaxProtocol,
        in context: some SwiftSyntaxMacros.MacroExpansionContext
    ) throws -> [SwiftSyntax.AttributeSyntax] {
        guard let variable = member.as(VariableDeclSyntax.self) else {
            return []
        }
        if variable.hasMacroApplication(named: TransientPropertyMacro.name) {
            return []
        }
        if variable.hasMacroApplication(named: RelationshipMacro.name) {
            return []
        }

        return [
            SwiftSyntax.AttributeSyntax(
                leadingTrivia: .space,
                atSign: .atSignToken(),
                attributeName: SwiftSyntax.IdentifierTypeSyntax(
                    name: .identifier(PersistedPropertyMacro.name)
                ),
                trailingTrivia: .space
            )
        ]
    }

    public static func expansion(
        of node: SwiftSyntax.AttributeSyntax,
        attachedTo declaration: some SwiftSyntax.DeclGroupSyntax,
        providingExtensionsOf type: some SwiftSyntax.TypeSyntaxProtocol,
        conformingTo protocols: [SwiftSyntax.TypeSyntax],
        in context: some SwiftSyntaxMacros.MacroExpansionContext
    ) throws -> [SwiftSyntax.ExtensionDeclSyntax] {
        guard declaration.is(ClassDeclSyntax.self) else {
            context.diagnose(
                Diagnostic(
                    node: Syntax(declaration),
                    message: ModelMacroDiagnostic(
                        message: "@CloudModel can only be attached to a class",
                        messageID: "cloud-model-class-only"
                    )
                )
            )
            return []
        }
        if protocols.contains(where: { $0.description == qualifiedConformanceName }) {
            return []
        }

        let modelExtension: DeclSyntax = """
        extension \(type): \(raw: qualifiedConformanceName) { }
        """
        let persistentExtension: DeclSyntax = """
        extension \(type): \(raw: persistentConformanceName) { }
        """
        let observationExtension: DeclSyntax = """
        extension \(type): Observable { }
        """

        return [
            modelExtension.cast(ExtensionDeclSyntax.self),
            persistentExtension.cast(ExtensionDeclSyntax.self),
            observationExtension.cast(ExtensionDeclSyntax.self)
        ]
    }
}
