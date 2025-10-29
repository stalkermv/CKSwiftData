//
//  Created by Valeriy Malishevskyi on 27.02.2024.
//

import SwiftSyntax

extension DeclGroupSyntax {
    /// Adds a declaration to the list if it's not already present and is needed.
    func addIfNeeded(_ decl: DeclSyntax?, to declarations: inout [DeclSyntax]) {
        guard let decl = decl else { return }

        // Determine if the declaration should be added based on its type.
        if let functionDecl = decl.as(FunctionDeclSyntax.self) {
            addFunctionIfUnique(functionDecl, to: &declarations)
        } else if let variableDecl = decl.as(VariableDeclSyntax.self) {
            addPropertyIfUnique(variableDecl, to: &declarations)
        }
    }

    // MARK: - Helper Methods

    /// Adds a function declaration to the list if an equivalent one doesn't already exist.
    private func addFunctionIfUnique(_ function: FunctionDeclSyntax, to declarations: inout [DeclSyntax]) {
        if !hasMemberFunction(equivalentTo: function) {
            declarations.append(function.cast(DeclSyntax.self))
        }
    }

    /// Adds a variable (property) declaration to the list if an equivalent one doesn't already exist.
    private func addPropertyIfUnique(_ property: VariableDeclSyntax, to declarations: inout [DeclSyntax]) {
        if !hasMemberProperty(equivalentTo: property) {
            declarations.append(property.cast(DeclSyntax.self))
        }
    }

    /// Determines if the group already contains an equivalent function declaration.
    private func hasMemberFunction(equivalentTo other: FunctionDeclSyntax) -> Bool {
        // Iterate through all members of the declaration group
        for member in memberBlock.members {
            if let function = member.as(MemberBlockItemSyntax.self)?.decl.as(FunctionDeclSyntax.self) {
                if function.isEquivalent(to: other) {
                    return true
                }
            }
        }
        return false
    }

    /// Determines if the group already contains an equivalent variable (property) declaration.
    private func hasMemberProperty(equivalentTo other: VariableDeclSyntax) -> Bool {
        for member in memberBlock.members {
            if let variable = member.as(MemberBlockItemSyntax.self)?.decl.as(VariableDeclSyntax.self) {
                if variable.isEquivalent(to: other) {
                    return true
                }
            }
        }
        return false
    }
}

extension FunctionDeclSyntax {
    /// Compares this function declaration to another to determine if they represent the same function signature.
    func isEquivalent(to other: FunctionDeclSyntax) -> Bool {
        // First, check if the function names are the same
        guard self.name.text == other.name.text else {
            return false
        }

        // Check if the number of parameters is the same
        let parameters1 = self.signature.parameterClause.parameters
        let parameters2 = other.signature.parameterClause.parameters
        guard parameters1.count == parameters2.count else {
            return false
        }

        // Compare each parameter's type
        for (param1, param2) in zip(parameters1, parameters2) {
            if param1.type.description != param2.type.description {
                return false
            }
        }

        // Optionally, compare the return types if needed
        let returnType1 = self.signature.returnClause?.type.description ?? "Void"
        let returnType2 = other.signature.returnClause?.type.description ?? "Void"
        if returnType1 != returnType2 {
            return false
        }

        // If all checks passed, the functions are considered equivalent
        return true
    }
}


extension VariableDeclSyntax {

    var identifierPattern: IdentifierPatternSyntax? {
        bindings.first?.pattern.as(IdentifierPatternSyntax.self)
    }


    func isEquivalent(to other: VariableDeclSyntax) -> Bool {
        guard self.isInstanceProperty == other.isInstanceProperty else {
            return false
        }
        return self.identifierPattern?.identifier == other.identifierPattern?.identifier
    }
    
    var isInstanceProperty: Bool {
        modifiers.contains { $0.name.text == "static" }
    }
}
