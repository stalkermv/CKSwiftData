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

            let typeText = property.bindings.first?.typeAnnotation?.type.description
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
                let destinationArgument = destination.map { "\"\($0)\"" } ?? "\"\""
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
                }.map { ModelMacro.inverseName(from: $0.expression.description) }
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

    static func inverseName(from expression: String) -> String {
        expression.split(separator: ".").last.map(String.init) ?? expression
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
