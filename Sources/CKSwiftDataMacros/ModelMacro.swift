//
//  Created by Valeriy Malishevskyi on 26.02.2024.
//

import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

public enum ModelMacro: MemberMacro, MemberAttributeMacro, ExtensionMacro {
    
    static var conformanceName: String {
        return "CloudKitModel"
    }
    
    static var qualifiedConformanceName: String {
        return "\(Module.name).\(conformanceName)"
    }
    
    // MARK: - MemberMacro
    
    static func persistentBackingData(_ className: TokenSyntax) -> DeclSyntax {
        return """
        public var persistentBackingData: any \(raw: Module.name).BackingData<\(className)> {
            get { _$backingData }
            set { _$backingData = newValue }
        }
        """
    }
    
    static func transientBackingData(_ className: TokenSyntax) -> DeclSyntax {
        return """
        @Transient private var _$backingData: any \(raw: Module.name).BackingData<\(className)> = \(className).createBackingData()
        """
    }
    
    static func initWithBackingData(
        _ className: TokenSyntax,
        properties: [VariableDeclSyntax],
        isPublic: Bool,
        isRequired: Bool
    ) -> DeclSyntax {
        let required = isRequired ? "required " : ""
        let access = isPublic ? "public " : ""
        
        let propertiesInitialization = properties
            .filter { property in
                property.hasMacroApplication(named: TransientPropertyMacro.name) == false
            }
            .map { property in
                guard let propertyName = property.bindings.first?
                    .pattern.firstToken(viewMode: .sourceAccurate)?.text else {
                    return ""
                }
                return "_\(propertyName) = _SwiftDataNoType()"
            }
            .joined(separator: "\n")
        
        // Combine everything into the final initializer code
        let initializerCode: DeclSyntax = """
        \(raw: access)\(raw: required)init(backingData: any \(raw: Module.name).BackingData<\(raw: className.text)>) {
            \(raw: propertiesInitialization)
            self.persistentBackingData = backingData
        }
        """
        
        return initializerCode
    }
    
    
    static func observationRegistrar(_ className: TokenSyntax) -> DeclSyntax {
        return """
        @Transient public let _$observationRegistrar = Observation.ObservationRegistrar()
        """
    }
    
    static func placeholderType(_ className: TokenSyntax) -> DeclSyntax {
        return """
        struct _SwiftDataNoType {}
        """
    }
    
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Try to cast the declaration to ClassDeclSyntax to access modifiers
        guard let classDeclSyntax = declaration.as(ClassDeclSyntax.self) else {
            return []
        }
        
        var declarations = [DeclSyntax]()
        let className = classDeclSyntax.name
        // Collect properties up-front for helpers that need them
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
        
        // Check if the class is public and final
        let isPublic = classDeclSyntax.modifiers.contains(where: { $0.name.text == "public" })
        let isFinal = classDeclSyntax.modifiers.contains(where: { $0.name.text == "final" })
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
        
        let schemaMetadataDecl = ModelMacro.schemaMetadata(
            for: className,
            with: properties,
            in: context
        )
        
        declarations.append(schemaMetadataDecl)
        return declarations
    }
    
    static func schemaMetadata(
        for className: TokenSyntax,
        with properties: [VariableDeclSyntax],
        in context: some MacroExpansionContext
    ) -> DeclSyntax {
        let metadataItems = properties.compactMap { property -> String? in
            guard let propertyName = property.bindings.first?.pattern.firstToken(viewMode: .sourceAccurate)?.text else { return nil }
            
            let typeText = property.bindings.first?.typeAnnotation?.type.description
            
            let defaultValue: String = if let initExpr = property.bindings.first?.initializer?.value {
                initExpr.description
            } else if let typeText, typeText.hasSuffix("?") {
                "Optional<\(String(typeText.dropLast()))>.none"
            } else {
                "nil"
            }
            
            let attributes = property.attributes.compactMap { $0.as(AttributeSyntax.self) }
            // Only construct metadata from an explicit @Relationship attribute on the property.
            let relationshipAttr = attributes.first { attr in
                let attrName = attr.attributeName.description
                // Use hasPrefix instead of exact match to handle comments
                return attrName.hasPrefix("Relationship")
            }
            let metadata: String
            if let rel = relationshipAttr {
                let args = rel.arguments?.description ?? ""
                if args.isEmpty {
                    metadata = "\(Module.name).Schema.Relationship()"
                } else {
                    metadata = "\(Module.name).Schema.Relationship(\(args))"
                }
            } else {
                metadata = "nil"
            }
            return """
                \(Module.name).Schema.PropertyMetadata(name: "\(propertyName)", keypath: \\\(className).\(propertyName), defaultValue: \(defaultValue), metadata: \(metadata))
                """
        }.joined(separator: ",\n")
        
        let schemaMetadataDecl: DeclSyntax = """
            public static var schemaMetadata: [\(raw: Module.name).Schema.PropertyMetadata] {
                return [
                    \(raw: metadataItems)
                ]
            }
            """
        
        return schemaMetadataDecl
    }
    
    // MARK: - MemberAttributeMacro
    // Member Attribute Macros are a category of macros in Swift specifically designed to add attributes to individual members of types or extensions.
    
    public static func expansion(
        of node: SwiftSyntax.AttributeSyntax,
        attachedTo declaration: some SwiftSyntax.DeclGroupSyntax,
        providingAttributesFor member: some SwiftSyntax.DeclSyntaxProtocol,
        in context: some SwiftSyntaxMacros.MacroExpansionContext
    ) throws -> [SwiftSyntax.AttributeSyntax] {
        // PersistedProperty to every property which not marked as transient
        
        guard let variable = member.as(VariableDeclSyntax.self) else {
            return []
        }
        
        if variable.hasMacroApplication(named: TransientPropertyMacro.name) {
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
    
    // MARK: - ExtensionMacro
    // An extension macro role can be used with the @attached macro attribute, and it can add a conformance, a where clause, and a member list in an extension on the type the macro is attached to.
    
    public static func expansion(
        of node: SwiftSyntax.AttributeSyntax,
        attachedTo declaration: some SwiftSyntax.DeclGroupSyntax,
        providingExtensionsOf type: some SwiftSyntax.TypeSyntaxProtocol,
        conformingTo protocols: [SwiftSyntax.TypeSyntax],
        in context: some SwiftSyntaxMacros.MacroExpansionContext
    ) throws -> [SwiftSyntax.ExtensionDeclSyntax] {
        if protocols.contains(where: { $0.description == qualifiedConformanceName }) {
            return []
        }
        
        let extensionDecl: DeclSyntax =
        """
        extension \(type): \(raw: qualifiedConformanceName) { }
        """
        
        let observationExtension: DeclSyntax =
        """
        extension \(type): Observable { }
        """
        
        return [
            extensionDecl.cast(ExtensionDeclSyntax.self),
            observationExtension.cast(ExtensionDeclSyntax.self)
        ]
    }
}
