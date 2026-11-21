import Foundation
import SwiftSyntax

extension ModelMacro {
    static func metadataCacheIsStable(
        modelAttribute: AttributeSyntax,
        classDeclaration: ClassDeclSyntax
    ) -> Bool {
        let arguments = modelAttribute.arguments?.as(LabeledExprListSyntax.self)
        let schemaVersion = arguments?.first { $0.label?.text == "schemaVersion" }?.expression
        guard schemaVersion == nil || isStableIntegerLiteral(schemaVersion) else {
            return false
        }

        guard let recordType = arguments?.first(where: { $0.label?.text == "recordType" })?.expression,
              isStableStringLiteral(recordType)
        else {
            return false
        }

        let properties = classDeclaration.memberBlock.members.compactMap { member in
            member.decl.as(VariableDeclSyntax.self)
        }
        return properties.allSatisfy(isStableSchemaProperty)
    }

    private static func isStableSchemaProperty(_ property: VariableDeclSyntax) -> Bool {
        if property.hasMacroApplication(named: TransientPropertyMacro.name) {
            return true
        }

        let attributes = property.attributes.compactMap { $0.as(AttributeSyntax.self) }
        if let relationship = attributes.first(where: {
            $0.attributeName.description.hasPrefix("Relationship")
        }) {
            return isStableRelationship(relationship)
        }
        guard let attribute = attributes.first(where: {
            $0.attributeName.description.hasPrefix("Attribute")
        }) else {
            return true
        }
        return isStableAttribute(attribute)
    }

    private static func isStableAttribute(_ attribute: AttributeSyntax) -> Bool {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else {
            return true
        }
        return arguments.allSatisfy { argument in
            switch argument.label?.text {
            case nil:
                isStableAttributeOption(argument.expression)
            case "originalName", "hashModifier":
                isStableOptionalString(argument.expression)
            default:
                false
            }
        }
    }

    private static func isStableRelationship(_ relationship: AttributeSyntax) -> Bool {
        guard let arguments = relationship.arguments?.as(LabeledExprListSyntax.self) else {
            return true
        }
        return arguments.allSatisfy { argument in
            switch argument.label?.text {
            case "deleteRule":
                isStableDeleteRule(argument.expression)
            case "minimum", "maximum":
                isStableIntegerLiteral(argument.expression)
            case "originalName", "inverseName", "hashModifier":
                isStableOptionalString(argument.expression)
            case "inverse":
                isNilLiteral(argument.expression)
            default:
                false
            }
        }
    }

    private static func isStableStringLiteral(_ expression: ExprSyntax?) -> Bool {
        guard let string = expression?.as(StringLiteralExprSyntax.self) else {
            return false
        }
        return string.segments.allSatisfy { segment in
            segment.as(ExpressionSegmentSyntax.self) == nil
        }
    }

    private static func isStableOptionalString(_ expression: ExprSyntax?) -> Bool {
        isNilLiteral(expression) || isStableStringLiteral(expression)
    }

    private static func isStableIntegerLiteral(_ expression: ExprSyntax?) -> Bool {
        expression?.as(IntegerLiteralExprSyntax.self) != nil
    }

    private static func isNilLiteral(_ expression: ExprSyntax?) -> Bool {
        expression?.as(NilLiteralExprSyntax.self) != nil
    }

    private static func isStableAttributeOption(_ expression: ExprSyntax) -> Bool {
        guard let member = expression.as(MemberAccessExprSyntax.self),
              member.base == nil
        else {
            return false
        }
        return stableAttributeOptionNames.contains(member.declName.baseName.text)
    }

    private static func isStableDeleteRule(_ expression: ExprSyntax) -> Bool {
        guard let member = expression.as(MemberAccessExprSyntax.self),
              member.base == nil
        else {
            return false
        }
        return stableDeleteRuleNames.contains(member.declName.baseName.text)
    }

    private static let stableAttributeOptionNames: Set<String> = [
        "unique",
        "externalStorage",
        "allowsCloudEncryption",
        "preserveValueOnDeletion",
        "ephemeral",
        "spotlight"
    ]

    private static let stableDeleteRuleNames: Set<String> = [
        "noAction",
        "nullify",
        "cascade",
        "deny"
    ]
}
