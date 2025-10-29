//
//  Created by Valeriy Malishevskyi on 26.02.2024.
//

import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

enum MacroExpansionError: Error {
    case macroNotApplicable
    case unexpectedDeclarationType
    case missingVariableName
    case missingTypeAnnotation
}

public enum PersistedPropertyMacro: AccessorMacro, PeerMacro {
    static let name = "PersistedProperty"
    static let backingData = "_$backingData"
    static let observationRegistrar = "_$observationRegistrar"
    
    static var transientAttribute: AttributeSyntax {
        AttributeSyntax(
            leadingTrivia: .space,
            atSign: .atSignToken(),
            attributeName: IdentifierTypeSyntax(
                name: .identifier(TransientPropertyMacro.name)
            ),
            trailingTrivia: .space
        )
    }
    
    // MARK: - AccessorMacro
    // Creates initializers, getters and setters for the property
    
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let property = declaration.as(VariableDeclSyntax.self) else {
            throw MacroExpansionError.macroNotApplicable
        }
        
        var accessors: [AccessorDeclSyntax] = []
        
        for binding in property.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier else {
                throw MacroExpansionError.macroNotApplicable
            }
            
            let initAccessor: AccessorDeclSyntax =
            """
            @storageRestrictions(accesses: _$backingData, initializes: _\(identifier))
            init(initialValue) {
                _$backingData.setValue(forKey: \\.\(identifier), to: initialValue)
                _\(identifier) = _SwiftDataNoType()
            }
            """
            
            let getAccessor: AccessorDeclSyntax =
            """
            get {
                _$observationRegistrar.access(self, keyPath: \\.\(identifier))
                return self.getValue(forKey: \\.\(identifier))
            }
            """
            
            let setAccessor: AccessorDeclSyntax =
            """
            set {
                _$observationRegistrar.withMutation(of: self, keyPath: \\.\(identifier)) {
                    self.setValue(forKey: \\.\(identifier), to: newValue)
                }
            }
            """
            
            accessors.append(contentsOf: [initAccessor, getAccessor, setAccessor])
        }
        
        return accessors
    }
    
    // MARK: - PeerMacro
    
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let property = declaration.as(VariableDeclSyntax.self) else {
            throw MacroExpansionError.macroNotApplicable
        }
        
        // If has macro `@Transient` ignore it.
        
        if property.hasMacroApplication(named: TransientPropertyMacro.name) {
            return []
        }
        
        guard let identifier = property.identifierPattern?.identifier else {
            throw MacroExpansionError.macroNotApplicable
        }
        
        let declarationModifier: AccessorDeclSyntax =
        """
        @Transient
        private var _\(identifier): _SwiftDataNoType
        """
        
        return [declarationModifier.cast(DeclSyntax.self)]
    }
}

extension VariableDeclSyntax {
    func hasPropertyWrapper(named name: String) -> Bool {
        attributes.contains { attr in
            guard let a = attr.as(AttributeSyntax.self) else { return false }
            return a.attributeName.trimmedDescription == name
        }
    }
}
