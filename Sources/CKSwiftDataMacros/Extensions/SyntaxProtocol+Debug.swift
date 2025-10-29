//
//  SyntaxProtocol+Debug.swift
//  Mem
//
//  Created by Valeriy Malishevskyi on 01.09.2025.
//

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

extension SyntaxProtocol {
    func debug(_ message: String) throws {
        throw DiagnosticsError(
            syntax: self,
            message: "Model macro can only be applied to classes",
            id: .missingInitializer
        )
    }
}
