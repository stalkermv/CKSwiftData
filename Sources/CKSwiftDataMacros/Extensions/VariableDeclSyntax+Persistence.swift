import SwiftDiagnostics
import SwiftSyntax

extension VariableDeclSyntax {
    /// Why this member of a `@CloudModel` class cannot be persisted, or `nil`
    /// when it is a stored `var` with one name and an explicit type.
    ///
    /// `@Transient` members are never persisted and are not checked. Every
    /// other member must be a plain stored property, because the macro gives
    /// it backing storage, accessors, and a schema entry.
    var persistenceRestriction: ModelMacroDiagnostic? {
        guard hasMacroApplication(named: TransientPropertyMacro.name) == false else {
            return nil
        }
        let modifierKinds = modifiers.map(\.name.tokenKind)
        if modifierKinds.contains(.keyword(.static)) || modifierKinds.contains(.keyword(.class)) {
            return ModelMacroDiagnostic(
                message: "@CloudModel cannot persist a static or class property; mark it @Transient or declare it in an extension",
                messageID: "cloud-model-static-member"
            )
        }
        if bindings.count != 1 {
            return ModelMacroDiagnostic(
                message: "@CloudModel persists one property per declaration; declare each property separately",
                messageID: "cloud-model-multiple-bindings"
            )
        }
        if bindingSpecifier.tokenKind != .keyword(.var) {
            return ModelMacroDiagnostic(
                message: "@CloudModel persists only 'var' properties; use 'var' or mark it @Transient",
                messageID: "cloud-model-let-member"
            )
        }
        if modifierKinds.contains(.keyword(.lazy)) {
            return ModelMacroDiagnostic(
                message: "@CloudModel cannot persist a lazy property; mark it @Transient",
                messageID: "cloud-model-lazy-member"
            )
        }
        if modifierKinds.contains(.keyword(.weak)) || modifierKinds.contains(.keyword(.unowned)) {
            return ModelMacroDiagnostic(
                message: "@CloudModel cannot persist a weak or unowned property; mark it @Transient",
                messageID: "cloud-model-weak-member"
            )
        }
        guard let binding = bindings.first,
              binding.pattern.is(IdentifierPatternSyntax.self)
        else {
            return ModelMacroDiagnostic(
                message: "@CloudModel persists only properties with a single name",
                messageID: "cloud-model-pattern-member"
            )
        }
        if let accessorBlock = binding.accessorBlock {
            if accessorBlock.declaresGetter {
                return ModelMacroDiagnostic(
                    message: "@CloudModel cannot persist a computed property; declare it in an extension",
                    messageID: "cloud-model-computed-member"
                )
            }
            return ModelMacroDiagnostic(
                message: "@CloudModel generates the accessors of a persisted property; remove the custom accessors or observers",
                messageID: "cloud-model-custom-accessors"
            )
        }
        if binding.typeAnnotation == nil {
            return ModelMacroDiagnostic(
                message: "@CloudModel needs an explicit type for a persisted property",
                messageID: "cloud-model-untyped-member"
            )
        }
        return nil
    }
}

private extension AccessorBlockSyntax {
    /// A body without accessor keywords, or a list with a `get` accessor.
    /// Only observers (`willSet`, `didSet`) remain for a stored property.
    var declaresGetter: Bool {
        switch accessors {
        case .getter:
            true
        case let .accessors(list):
            list.contains { $0.accessorSpecifier.tokenKind == .keyword(.get) }
        }
    }
}
