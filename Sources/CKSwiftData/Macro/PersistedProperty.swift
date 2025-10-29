//
//  Created by Valeriy Malishevskyi on 07.02.2024.
//

import Foundation

@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(`_`))
public macro PersistedProperty() = #externalMacro(module: "CKSwiftDataMacros", type: "PersistedPropertyMacro")
