//
//  Created by Valeriy Malishevskyi on 26.02.2024.
//

import SwiftSyntax

extension DeclModifierListSyntax {
    /// Prepends a 'private' modifier to the list, removing any existing access level modifiers.
    func makePrivatePrefixed(with prefix: String) -> DeclModifierListSyntax {
        // Create a 'private' modifier with a trailing space for readability.
        let privateModifier = createPrivateModifier()

        // Filter out any existing access level modifiers from the current list.
        let filteredModifiers = filterOutAccessModifiers()

        // Prepend the 'private' modifier to the filtered list of modifiers.
        return [privateModifier] + filteredModifiers
    }

    /// Creates a 'private' declaration modifier with trailing space.
    private func createPrivateModifier() -> DeclModifierSyntax {
        DeclModifierSyntax(name: "private", trailingTrivia: .space)
    }

    /// Filters out access level modifiers from the declaration modifier list.
    private func filterOutAccessModifiers() -> DeclModifierListSyntax {
        filter { modifier in
            guard case .keyword(let keyword) = modifier.name.tokenKind else {
                return true // Keep non-keyword modifiers.
            }
            return !isAccessLevelModifier(keyword)
        }
    }

    /// Determines if the given keyword represents an access level modifier.
    private func isAccessLevelModifier(_ keyword: Keyword) -> Bool {
        switch keyword {
        case .fileprivate, .private, .internal, .public:
            return false // These are access level modifiers, should be filtered out.
        default:
            return true // Not an access level modifier.
        }
    }
}
