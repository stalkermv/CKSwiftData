//
//  Created by Valeriy Malishevskyi on 07.02.2024.
//

import Foundation

extension Array: RelationshipCollection where Element: CloudKitModel {
    public typealias PersistentElement = Element
}
