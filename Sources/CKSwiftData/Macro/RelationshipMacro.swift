//
//  Created by Valeriy Malishevskyi on 26.02.2024.
//

/// A macro that generates relationship properties with both direct access and projected values.
///
/// For a property declared as:
/// ```swift
/// @Relationship var snippets: [Snippet]?
/// ```
///
/// The macro generates:
/// - Normal property accessors that work with backing data
/// - A projected property `$snippets` that provides `Relationship<...>` interface
/// - Proper storage restrictions and observation integration
///
/// The projected property allows for relationship manipulation using syntax like:
/// ```swift
/// folder.$snippets = .ids(["snippet1", "snippet2"])
/// folder.$snippets = .models([snippet1, snippet2])
/// ```
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(`$`), prefixed(`_`))
public macro Relationship(
    deleteRule: Schema.Relationship.DeleteRule = .nullify,
    inverse: AnyKeyPath? = nil,
    minimum: Int = 0,
    maximum: Int = 0,
    originalName: String? = nil,
    inverseName: String? = nil,
    hashModifier: String? = nil
) = #externalMacro(module: "CKSwiftDataMacros", type: "RelationshipMacro")
