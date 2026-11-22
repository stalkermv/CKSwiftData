//
//  Created by Valeriy Malishevskyi on 26.02.2024.
//

import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

struct ModelMacroDiagnostic: DiagnosticMessage {
    let message: String
    let messageID: String

    var diagnosticID: MessageID {
        MessageID(domain: "CKSwiftDataMacros", id: messageID)
    }

    var severity: DiagnosticSeverity { .error }
}

public enum ModelMacro: MemberMacro, MemberAttributeMacro, ExtensionMacro {
    static var conformanceName: String {
        "CloudKitModel"
    }

    static var qualifiedConformanceName: String {
        "\(Module.name).\(conformanceName)"
    }

    static var persistentConformanceName: String {
        "\(Module.name).CloudPersistentModel"
    }

    // MARK: - MemberMacro

    static func persistentBackingData(_ className: TokenSyntax) -> DeclSyntax {
        """
        public var persistentBackingData: any \(raw: Module.name).BackingData<\(className)> {
            get { _$backingData }
            set { _$backingData = newValue }
        }
        """
    }

    static func transientBackingData(_ className: TokenSyntax) -> DeclSyntax {
        """
        @Transient private var _$backingData: any \(raw: Module.name).BackingData<\(className)> = \(className).createBackingData()
        """
    }

    static func initWithBackingData(
        _ className: TokenSyntax,
        properties: [VariableDeclSyntax],
        isPublic: Bool,
        isRequired: Bool
    ) -> DeclSyntax {
        let required = isRequired ? "required " : ""
        let access = isPublic ? "public " : ""

        let propertiesInitialization = properties
            .filter { property in
                property.hasMacroApplication(named: TransientPropertyMacro.name) == false
            }
            .map { property in
                guard let propertyName = property.bindings.first?
                    .pattern.firstToken(viewMode: .sourceAccurate)?.text
                else {
                    return ""
                }
                return "_\(propertyName) = _SwiftDataNoType()"
            }
            .joined(separator: "\n")

        // Combine everything into the final initializer code
        let initializerCode: DeclSyntax = """
        \(raw: access)\(raw: required)init(backingData: any \(raw: Module.name).BackingData<\(raw: className.text)>) {
            \(raw: propertiesInitialization)
            self.persistentBackingData = backingData
        }
        """

        return initializerCode
    }

    static func defaultInitializer(
        _ className: TokenSyntax,
        isPublic: Bool
    ) -> DeclSyntax {
        let access = isPublic ? "public " : ""
        return """
        \(raw: access)convenience init() {
            self.init(backingData: \(raw: className).createBackingData())
        }
        """
    }

    static func declarationConfiguration(
        from node: AttributeSyntax,
        className: TokenSyntax,
        isPublic: Bool,
        metadataCacheIsStable: Bool
    ) -> [DeclSyntax] {
        let arguments = node.arguments?.as(LabeledExprListSyntax.self)
        let access = isPublic ? "public " : ""
        let schemaVersion = arguments?.first { $0.label?.text == "schemaVersion" }?
            .expression.description ?? "1"
        var declarations: [DeclSyntax] = [
            """
            \(raw: access)static var cloudSchemaVersion: Int {
                \(raw: schemaVersion)
            }
            """,
            """
            \(raw: access)static var cloudModelRuntimeMetadataIsStable: Bool {
                \(raw: metadataCacheIsStable ? "true" : "false")
            }
            """
        ]

        // Without an explicit record type the class name is used. It is
        // generated as a literal so that the runtime can cache the schema.
        let explicitRecordType = arguments?.first(where: { $0.label?.text == "recordType" })?
            .expression.description
        let recordType = explicitRecordType.flatMap { $0 == "nil" ? nil : $0 }
            ?? "\"\(className.text)\""
        declarations.append(
            """
            \(raw: access)static var recordType: String {
                \(raw: recordType)
            }
            """
        )
        declarations.append(
            """
            \(raw: access)static var cloudRecordType: String {
                recordType
            }
            """
        )
        return declarations
    }

    static func observationRegistrar(_ className: TokenSyntax) -> DeclSyntax {
        """
        @Transient public let _$observationRegistrar = Observation.ObservationRegistrar()
        """
    }

    static func placeholderType(_ className: TokenSyntax) -> DeclSyntax {
        """
        struct _SwiftDataNoType {}
        """
    }
}
