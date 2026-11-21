//
//  Created by Valeriy Malishevskyi on 26.02.2024.
//

import SwiftSyntax

extension TokenSyntax {
    func makePrivatePrefixed(with prefix: String) -> TokenSyntax {
        switch tokenKind {
        case let .identifier(identifier):
            TokenSyntax(
                .identifier(prefix + identifier), leadingTrivia: leadingTrivia,
                trailingTrivia: trailingTrivia, presence: presence
            )
        default:
            self
        }
    }
}
