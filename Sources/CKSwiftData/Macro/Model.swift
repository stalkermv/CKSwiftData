//
//  Created by Valeriy Malishevskyi on 07.02.2024.
//

import Foundation

@attached(
    member,
    names: arbitrary
)
@attached(memberAttribute)
@attached(extension, conformances: Observable, CloudKitModel)
public macro CloudModel() = #externalMacro(
    module: "CKSwiftDataMacros",
    type: "ModelMacro"
)
