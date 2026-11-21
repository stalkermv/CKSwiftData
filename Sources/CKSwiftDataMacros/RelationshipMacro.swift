//
//  RelationshipMacro.swift
//  Mem
//
//  Created by Valeriy Malishevskyi on 01.09.2025.
//

import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public enum RelationshipMacro: AccessorMacro, PeerMacro {
    static let name = "Relationship"

    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let property = declaration.as(VariableDeclSyntax.self),
              property.bindings.count == 1,
              let binding = property.bindings.first,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier
        else {
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

        return [initAccessor, getAccessor, setAccessor]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let property = declaration.as(VariableDeclSyntax.self),
              property.bindings.count == 1,
              let identifier = property.identifierPattern?.identifier
        else {
            throw MacroExpansionError.macroNotApplicable
        }

        let backingProperty: DeclSyntax =
            """
            @Transient
            private var _\(identifier): _SwiftDataNoType
            """

        return [backingProperty]
    }
}
