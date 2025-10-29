//
//  Created by Valeriy Malishevskyi on 26.02.2024.
//

import SwiftDiagnostics
import SwiftSyntax

struct UniversalSwiftDataDiagnostic: DiagnosticMessage {
    enum ID: String {
        case invalidApplication = "invalid type"
        case missingInitializer = "missing initializer"
    }
    
    var message: String
    var diagnosticID: MessageID
    var severity: DiagnosticSeverity
    
    init(
        message: String, 
        diagnosticID: SwiftDiagnostics.MessageID,
        severity: SwiftDiagnostics.DiagnosticSeverity = .error
    ) {
        self.message = message
        self.diagnosticID = diagnosticID
        self.severity = severity
    }
    
    init(
        message: String,
        domain: String,
        id: ID,
        severity: SwiftDiagnostics.DiagnosticSeverity = .error
      ) {
        self.message = message
        self.diagnosticID = MessageID(domain: domain, id: id.rawValue)
        self.severity = severity
      }
}

extension DiagnosticsError {
    init<S: SyntaxProtocol>(
        syntax: S,
        message: String,
        domain: String = "UniversalSwiftData",
        id: UniversalSwiftDataDiagnostic.ID,
        severity: SwiftDiagnostics.DiagnosticSeverity = .error
    ) {
        let message = UniversalSwiftDataDiagnostic(
            message: message,
            domain: domain,
            id: id,
            severity: severity
        )
        
        let diagnostic = Diagnostic(node: Syntax(syntax), message: message)
        self.init(diagnostics: [diagnostic])
    }
}
