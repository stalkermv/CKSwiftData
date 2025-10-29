//
//  Created by Valeriy Malishevskyi on 07.02.2024.
//

import Foundation

extension Schema {
    
    /// An object that describes the configuration and behavior of a relationship between two model classes.
    final public class Relationship : SchemaProperty {
        
        final public var name: String
        
        final public var originalName: String
        
        final public var keypath: AnyKeyPath?
        
        final public var options: [Schema.Relationship.Option]
        
        final public var valueType: Any.Type
        
        final public var destination: String
        
        final public var deleteRule: Schema.Relationship.DeleteRule
        
        final public var inverseName: String?
        
        final public var inverseKeyPath: AnyKeyPath?
        
        final public var minimumModelCount: Int?
        
        final public var maximumModelCount: Int?
        
        final public var hashModifier: String?
        
        final public var isToOneRelationship: Bool {
            guard let keypath else { return false }
            return type(of: keypath).valueType is (any RelationshipCollection.Type) == false
        }
        
        public init(
            _ options: Schema.Relationship.Option... ,
            deleteRule: Schema.Relationship.DeleteRule = .nullify,
            minimumModelCount: Int? = 0,
            maximumModelCount: Int? = 0,
            originalName: String? = nil,
            inverse: AnyKeyPath? = nil,
            hashModifier: String? = nil
        ) {
            self.name = ""
            self.originalName = originalName ?? ""
            self.keypath = nil
            self.options = options
            self.valueType = Any.self
            self.destination = ""
            self.deleteRule = deleteRule
            self.inverseName = nil
            self.inverseKeyPath = inverse
            self.minimumModelCount = minimumModelCount
            self.maximumModelCount = maximumModelCount
            self.hashModifier = hashModifier
        }
        
        final public var isUnique: Bool {
            options.contains(.unique)
        }
        
        final public var isAttribute: Bool {
            // This is a Relationship schema node, not an Attribute
            return false
        }

        /// Indicates whether the relationship is optional.
        final public var isOptional: Bool {
            return minimumModelCount == 0
        }
        
        final public var isTransient: Bool {
            // TODO: Add .transient option when supported
            return false
        }
        
        final public var debugDescription: String {
            """
            Relationship(
                name: \(name),
                originalName: \(originalName),
                keypath: \(String(describing: keypath)),
                options: \(options),
                valueType: \(valueType),
                destination: \(destination),
                deleteRule: \(deleteRule),
                inverseName: \(String(describing: inverseName)),
                inverseKeyPath: \(String(describing: inverseKeyPath)),
                minimumModelCount: \(String(describing: minimumModelCount)),
                maximumModelCount: \(String(describing: maximumModelCount)),
                hashModifier: \(String(describing: hashModifier))
            )
            """
        }
        
        // MARK: Codable
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try container.decode(String.self, forKey: .name)
            self.originalName = try container.decode(String.self, forKey: .originalName)
            self.options = try container.decode([Schema.Relationship.Option].self, forKey: .options)
            self.destination = try container.decode(String.self, forKey: .destination)
            self.deleteRule = try container.decode(Schema.Relationship.DeleteRule.self, forKey: .deleteRule)
            self.inverseName = try container.decodeIfPresent(String.self, forKey: .inverseName)
            self.minimumModelCount = try container.decodeIfPresent(Int.self, forKey: .minimumModelCount)
            self.maximumModelCount = try container.decodeIfPresent(Int.self, forKey: .maximumModelCount)
            self.hashModifier = try container.decodeIfPresent(String.self, forKey: .hashModifier)
            
            // Non-codable runtime-only fields
            self.keypath = nil
            self.inverseKeyPath = nil
            self.valueType = Any.self
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(originalName, forKey: .originalName)
            try container.encode(options, forKey: .options)
            try container.encode(destination, forKey: .destination)
            try container.encode(deleteRule, forKey: .deleteRule)
            try container.encodeIfPresent(inverseName, forKey: .inverseName)
            try container.encodeIfPresent(minimumModelCount, forKey: .minimumModelCount)
            try container.encodeIfPresent(maximumModelCount, forKey: .maximumModelCount)
            try container.encodeIfPresent(hashModifier, forKey: .hashModifier)
        }
        
        // MARK: Hashable
        
        public static func == (lhs: Schema.Relationship, rhs: Schema.Relationship) -> Bool {
            lhs.name == rhs.name &&
            lhs.originalName == rhs.originalName &&
            lhs.destination == rhs.destination &&
            lhs.deleteRule == rhs.deleteRule &&
            lhs.inverseName == rhs.inverseName &&
            lhs.minimumModelCount == rhs.minimumModelCount &&
            lhs.maximumModelCount == rhs.maximumModelCount &&
            lhs.options == rhs.options &&
            lhs.hashModifier == rhs.hashModifier
        }
        
        public func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(originalName)
            hasher.combine(destination)
            hasher.combine(deleteRule)
            hasher.combine(inverseName)
            hasher.combine(minimumModelCount)
            hasher.combine(maximumModelCount)
            hasher.combine(options)
            hasher.combine(hashModifier)
        }
        
        private enum CodingKeys: String, CodingKey {
            case name
            case originalName
            case options
            case destination
            case deleteRule
            case inverseName
            case minimumModelCount
            case maximumModelCount
            case hashModifier
        }
    }
}

// MARK: - Relationship.Option

extension Schema.Relationship {
    public struct Option : Codable, Hashable, CustomDebugStringConvertible {
        
        let isUnique: Bool

        /// Ensures the property's value is unique across all models of the same type.
        public static var unique: Schema.Relationship.Option {
            Self(isUnique: true)
        }
        
        public var debugDescription: String {
            """
            Option(
                isUnique: \(isUnique)
            )
            """
        }
    }
}

// MARK: - DeleteRule

extension Schema.Relationship {
    /// Describes the rule to apply when deleting a model containing references to other models.
    public enum DeleteRule : String, Codable {

        /// A rule that doesn't make changes to any related models.
        ///
        /// Ensure that you take the appropriate action on any related models when using this delete rule,
        /// such as deleting them or nullifying their references to the deleted model. Otherwise, your data will
        /// be in an inconsistent state and may reference models that don't exist.
        case noAction

        /// A rule that nullifies the related model's reference to the deleted model.
        case nullify

        /// A rule that deletes any related models.
        case cascade

        /// A rule that prevents the deletion of a model because it contains one or more references to other
        /// models.
        case deny
    }
}

extension Schema.Relationship.DeleteRule : Equatable { }

extension Schema.Relationship.DeleteRule : Hashable { }

extension Schema.Relationship.DeleteRule : RawRepresentable { }
