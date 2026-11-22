import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension ModelMacro {
    static func schemaMetadata(
        for className: TokenSyntax,
        with properties: [VariableDeclSyntax],
        in context: some MacroExpansionContext
    ) -> DeclSyntax {
        let metadataItems = properties.compactMap { property -> String? in
            if property.hasMacroApplication(named: TransientPropertyMacro.name) {
                return nil
            }
            guard let propertyName = property.bindings.first?
                .pattern.firstToken(viewMode: .sourceAccurate)?.text
            else {
                return nil
            }

            let typeText = property.bindings.first?.typeAnnotation?.type.trimmedDescription
            let defaultValue: String = if let initExpr = property.bindings.first?.initializer?.value {
                initExpr.description
            } else if let typeText, typeText.hasSuffix("?") {
                "Optional<\(String(typeText.dropLast()))>.none"
            } else {
                "nil"
            }

            let attributes = property.attributes.compactMap { $0.as(AttributeSyntax.self) }
            let relationshipAttr = attributes.first { attr in
                attr.attributeName.description.hasPrefix("Relationship")
            }
            let metadata: String
            if let rel = relationshipAttr {
                let arguments = rel.arguments?.as(LabeledExprListSyntax.self)
                let options = arguments?.compactMap { argument -> String? in
                    argument.label == nil ? argument.expression.description : nil
                } ?? []
                let destination = ModelMacro.relationshipDestination(from: typeText)
                let destinationArgument = destination.map { "\($0).recordType" } ?? "\"\""
                let originalName = arguments?.first { $0.label?.text == "originalName" }?
                    .expression.description ?? "nil"
                let deleteRule = arguments?.first { $0.label?.text == "deleteRule" }?
                    .expression.description ?? ".nullify"
                let minimum = arguments?.first {
                    $0.label?.text == "minimum" || $0.label?.text == "minimumModelCount"
                }?.expression.description ?? "0"
                let maximum = arguments?.first {
                    $0.label?.text == "maximum" || $0.label?.text == "maximumModelCount"
                }?.expression.description ?? "nil"
                let explicitInverseName = arguments?.first { $0.label?.text == "inverseName" }
                    .map { ModelMacro.stringLiteralValue(from: $0.expression.description) }
                let inverseName = explicitInverseName ?? arguments?.first {
                    $0.label?.text == "inverse"
                }.flatMap {
                    ModelMacro.inverseName(from: $0, destination: destination, in: context)
                }
                let inverseArgument = inverseName.map { "\"\($0)\"" } ?? "nil"
                let optionsArgument = options.isEmpty ? "[]" : "[\(options.joined(separator: ", "))]"
                metadata = """
                \(Module.name).Schema.Relationship(
                    name: "\(propertyName)",
                    originalName: \(originalName),
                    options: \(optionsArgument),
                    destination: \(destinationArgument),
                    deleteRule: \(deleteRule),
                    minimumModelCount: \(minimum),
                    maximumModelCount: \(maximum),
                    inverseName: \(inverseArgument)
                )
                """
            } else {
                let attribute = attributes.first { attr in
                    attr.attributeName.description.hasPrefix("Attribute")
                }
                let arguments = attribute?.arguments?.as(LabeledExprListSyntax.self)
                let options = arguments?.compactMap { argument -> String? in
                    argument.label == nil ? argument.expression.description : nil
                } ?? []
                let originalName = arguments?.first { $0.label?.text == "originalName" }?
                    .expression.description
                let hashModifier = arguments?.first { $0.label?.text == "hashModifier" }?
                    .expression.description
                let typeArgument = typeText.map { "\($0).self" } ?? "Any.self"
                let optionalArgument = typeText?.hasSuffix("?") == true ? "true" : "false"
                metadata = """
                \(Module.name).Schema.Attribute(
                    name: "\(propertyName)",
                    originalName: \(originalName ?? "nil"),
                    options: [\(options.joined(separator: ", "))],
                    valueType: \(typeArgument),
                    defaultValue: \(defaultValue),
                    isOptional: \(optionalArgument),
                    hashModifier: \(hashModifier ?? "nil")
                )
                """
            }
            return """
            \(Module.name).Schema.PropertyMetadata(name: "\(propertyName)", keypath: \\\(className).\(propertyName), defaultValue: \(defaultValue), metadata: \(metadata))
            """
        }.joined(separator: ",\n")

        return """
        public static var schemaMetadata: [\(raw: Module.name).Schema.PropertyMetadata] {
            return [
                \(raw: metadataItems)
            ]
        }
        """
    }

    static func relationshipDestination(from typeText: String?) -> String? {
        guard var value = typeText.map({ String($0.filter { $0.isWhitespace == false }) }) else {
            return nil
        }
        if value.hasSuffix("?") { value.removeLast() }
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        } else if value.hasPrefix("Array<"), value.hasSuffix(">") {
            value = String(value.dropFirst("Array<".count).dropLast())
        } else if value.hasPrefix("Set<"), value.hasSuffix(">") {
            value = String(value.dropFirst("Set<".count).dropLast())
        }
        if let genericStart = value.firstIndex(of: "<") {
            value = String(value[..<genericStart])
        }
        guard value.isEmpty == false else { return nil }
        return value.split(separator: ".").last.map(String.init)
    }

    /// Reads the inverse property name from an `inverse:` key path such as
    /// `\TodoItem.project`. The key path must start at the relationship's
    /// destination type and name exactly one property.
    static func inverseName(
        from argument: LabeledExprSyntax,
        destination: String?,
        in context: some MacroExpansionContext
    ) -> String? {
        if argument.expression.is(NilLiteralExprSyntax.self) {
            return nil
        }
        guard let keyPath = argument.expression.as(KeyPathExprSyntax.self) else {
            context.diagnose(
                Diagnostic(
                    node: Syntax(argument.expression),
                    message: ModelMacroDiagnostic(
                        message: "The inverse must be a key path literal such as \\TodoItem.project",
                        messageID: "inverse-key-path-literal"
                    )
                )
            )
            return nil
        }
        let properties = keyPath.components.compactMap { $0.component.as(KeyPathPropertyComponentSyntax.self) }
        guard keyPath.components.count == 1, let property = properties.first else {
            context.diagnose(
                Diagnostic(
                    node: Syntax(keyPath),
                    message: ModelMacroDiagnostic(
                        message: "The inverse key path must name exactly one property",
                        messageID: "inverse-key-path-single-property"
                    )
                )
            )
            return nil
        }
        if let destination, let root = keyPath.root {
            let rootName = root.trimmedDescription.split(separator: ".").last.map(String.init)
            if rootName != destination {
                context.diagnose(
                    Diagnostic(
                        node: Syntax(root),
                        message: ModelMacroDiagnostic(
                            message: "The inverse key path must start at the destination type '\(destination)'",
                            messageID: "inverse-key-path-root"
                        )
                    )
                )
                return nil
            }
        }
        return property.declName.baseName.text
    }

    static func stringLiteralValue(from expression: String) -> String {
        guard expression.count >= 2,
              expression.first == "\"",
              expression.last == "\""
        else {
            return expression
        }
        return String(expression.dropFirst().dropLast())
    }
}
