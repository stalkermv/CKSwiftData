//
//  Created by Valeriy Malishevskyi on 26.02.2024.
//

import SwiftSyntax

extension VariableDeclSyntax {
    func hasMacroApplication(named name: String) -> Bool {
        attributes.contains { attribute in
            guard case let .attribute(attr) = attribute else { return false }
            return attr.attributeName.tokens(viewMode: .all).map(\.tokenKind) == [.identifier(name)]
        }
    }

    func makePrivatePrefixed(
        with prefix: String,
        adding attribute: AttributeSyntax
    ) -> VariableDeclSyntax {
        let newAttributes = attributes + [.attribute(attribute)]
        return VariableDeclSyntax(
            leadingTrivia: leadingTrivia,
            attributes: newAttributes,
            modifiers: modifiers.makePrivatePrefixed(with: prefix),
            bindingSpecifier: TokenSyntax(
                bindingSpecifier.tokenKind,
                leadingTrivia: .space,
                trailingTrivia: .space,
                presence: .present
            ),
            bindings: bindings.makePrivatePrefixed(with: prefix),
            trailingTrivia: trailingTrivia
        )
    }
}
