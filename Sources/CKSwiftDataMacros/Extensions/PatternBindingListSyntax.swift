//
//  Created by Valeriy Malishevskyi on 26.02.2024.
//

import SwiftSyntax

extension PatternBindingListSyntax {
    /// Prepends a prefix to the identifiers of the pattern bindings.
    func makePrivatePrefixed(with prefix: String) -> PatternBindingListSyntax {
        // Transform each binding in the list, prepending the prefix where applicable.
        let updatedBindings = self.map { binding in
            updateBinding(binding, withPrefix: prefix)
        }
        
        return PatternBindingListSyntax(updatedBindings)
    }
    
    /// Updates a single pattern binding with the given prefix, if applicable.
    private func updateBinding(_ binding: PatternBindingSyntax, withPrefix prefix: String) -> PatternBindingSyntax {
        guard let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
            return binding // Return the original binding if it's not an identifier pattern.
        }
        
        // Update the identifier within the pattern with the prefix.
        let updatedPattern = updateIdentifierPattern(identifierPattern, withPrefix: prefix)
        
        // Construct a new PatternBindingSyntax with the updated pattern and the original binding's properties.
        return PatternBindingSyntax(
            leadingTrivia: binding.leadingTrivia,
            pattern: updatedPattern,
            typeAnnotation: binding.typeAnnotation,
            initializer: binding.initializer,
            accessorBlock: binding.accessorBlock,
            trailingComma: binding.trailingComma,
            trailingTrivia: binding.trailingTrivia
        )
    }
    
    /// Updates an IdentifierPatternSyntax with the given prefix.
    private func updateIdentifierPattern(_ pattern: IdentifierPatternSyntax, withPrefix prefix: String) -> IdentifierPatternSyntax {
        // Prepend the prefix to the identifier within the pattern.
        let updatedIdentifier = pattern.identifier.makePrivatePrefixed(with: prefix)
        
        // Construct a new IdentifierPatternSyntax with the updated identifier and the original pattern's properties.
        return IdentifierPatternSyntax(
            leadingTrivia: pattern.leadingTrivia,
            identifier: updatedIdentifier,
            trailingTrivia: pattern.trailingTrivia
        )
    }
}
