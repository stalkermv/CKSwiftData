//
//  Created by Valeriy Malishevskyi on 26.02.2024.
//

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct MacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ModelMacro.self,
        TransientPropertyMacro.self,
        AttributeMacro.self,
        RelationshipMacro.self,
        PersistedPropertyMacro.self
    ]
}
