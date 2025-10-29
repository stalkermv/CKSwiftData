//
//  Created by Valeriy Malishevskyi on 07.02.2024.
//

import Foundation

extension Optional : RelationshipCollection
where Wrapped : Sequence, Wrapped.Element : CloudKitModel {
    public typealias PersistentElement = Wrapped.Element
}
