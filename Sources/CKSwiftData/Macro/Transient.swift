//
//  Created by Valeriy Malishevskyi on 07.02.2024.
//

import Foundation

/// Tells SwiftData not to persist the annotated property when managing the owning class.
@attached(peer) public macro Transient() = #externalMacro(module: "CKSwiftDataMacros", type: "TransientPropertyMacro")
