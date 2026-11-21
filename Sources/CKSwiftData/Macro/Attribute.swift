//
//  Created by Valeriy Malishevskyi on 07.02.2024.
//

import Foundation

@attached(peer)
public macro Attribute(
    _ options: Schema.Attribute.Option...,
    originalName: String? = nil,
    hashModifier: String? = nil
) = #externalMacro(module: "CKSwiftDataMacros", type: "AttributeMacro")
