//
//  Created by Valeriy Malishevskyi on 07.02.2024.
//

import Foundation

/// An interface for describing a property.
@available(swift 5.9)
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public protocol SchemaProperty : Decodable, Encodable, Hashable {

    var name: String { get set }

    var originalName: String { get set }

    var valueType: Any.Type { get set }

    var isAttribute: Bool { get }

    var isRelationship: Bool { get }

    var isTransient: Bool { get }

    var isOptional: Bool { get }

    var isUnique: Bool { get }
}

@available(swift 5.9)
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension SchemaProperty {

    public var isAttribute: Bool {
        return false
    }

    public var isRelationship: Bool {
        return false
    }

    public var isTransient: Bool {
        return false
    }

    public var isOptional: Bool {
        return false
    }
}
