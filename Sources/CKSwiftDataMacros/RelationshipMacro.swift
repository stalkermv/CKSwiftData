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

public enum RelationshipMacro: AccessorMacro {
    static let name = "Relationship"
    
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        return []
    }
}
