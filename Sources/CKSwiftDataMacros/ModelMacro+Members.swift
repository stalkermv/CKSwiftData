import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension ModelMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let classDeclSyntax = declaration.as(ClassDeclSyntax.self) else {
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

        var declarations = [DeclSyntax]()
        let className = classDeclSyntax.name
        let properties = declaration.memberBlock.members.compactMap { member in
            member.decl.as(VariableDeclSyntax.self)
        }

        declaration.addIfNeeded(
            ModelMacro.persistentBackingData(className),
            to: &declarations
        )
        declaration.addIfNeeded(
            ModelMacro.transientBackingData(className),
            to: &declarations
        )
        declaration.addIfNeeded(
            ModelMacro.observationRegistrar(className),
            to: &declarations
        )
        declaration.addIfNeeded(
            ModelMacro.placeholderType(className),
            to: &declarations
        )

        let isPublic = classDeclSyntax.modifiers.contains { $0.name.text == "public" }
        let isFinal = classDeclSyntax.modifiers.contains { $0.name.text == "final" }
        let hasUserInitializers = declaration.memberBlock.members.contains { member in
            member.decl.is(InitializerDeclSyntax.self)
        }

        declarations.append(
            ModelMacro.initWithBackingData(
                className,
                properties: properties,
                isPublic: isPublic,
                isRequired: !isFinal
            )
        )

        if hasUserInitializers == false {
            declarations.append(ModelMacro.defaultInitializer(className, properties: properties, isPublic: isPublic))
        }

        declarations.append(contentsOf: ModelMacro.declarationConfiguration(
            from: node,
            className: className,
            isPublic: isPublic,
            metadataCacheIsStable: ModelMacro.metadataCacheIsStable(
                modelAttribute: node,
                classDeclaration: classDeclSyntax
            )
        ))
        declarations.append(
            ModelMacro.schemaMetadata(for: className, with: properties, in: context)
        )
        return declarations
    }
}
