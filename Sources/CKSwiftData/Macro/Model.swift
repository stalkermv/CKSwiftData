//
//  Created by Valeriy Malishevskyi on 07.02.2024.
//

import Foundation

@attached(
    member,
    names: arbitrary
)
@attached(memberAttribute)
@attached(extension, conformances: Observable, CloudKitModel, CloudPersistentModel)
public macro CloudModel(
    recordType: String? = nil,
    schemaVersion: Int = 1
) = #externalMacro(
    module: "CKSwiftDataMacros",
    type: "ModelMacro"
)
