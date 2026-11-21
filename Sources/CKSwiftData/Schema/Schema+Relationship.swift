//
//  Created by Valeriy Malishevskyi on 07.02.2024.
//

import Foundation

extension Schema {
    /// An object that describes the configuration and behavior of a relationship between two model classes.
    public final class Relationship: SchemaProperty {
        public final var name: String

        public final var originalName: String

        public final var keypath: AnyKeyPath?

        public final var options: [Schema.Relationship.Option]

        public final var valueType: Any.Type

        public final var destination: String

        public final var deleteRule: Schema.Relationship.DeleteRule

        public final var inverseName: String?

        public final var inverseKeyPath: AnyKeyPath?

        public final var minimumModelCount: Int?

        public final var maximumModelCount: Int?

        public final var hashModifier: String?

        public final var isToOneRelationship: Bool {
            guard let keypath else { return false }
            return type(of: keypath).valueType is (any RelationshipCollection.Type) == false
        }

        public init(
            _ options: Schema.Relationship.Option...,
            deleteRule: Schema.Relationship.DeleteRule = .nullify,
            minimumModelCount: Int? = 0,
            maximumModelCount: Int? = nil,
            originalName: String? = nil,
            inverse: AnyKeyPath? = nil,
            hashModifier: String? = nil
        ) {
            name = ""
            self.originalName = originalName ?? ""
            keypath = nil
            self.options = options
            valueType = Any.self
            destination = ""
            self.deleteRule = deleteRule
            inverseName = nil
            inverseKeyPath = inverse
            self.minimumModelCount = minimumModelCount
            self.maximumModelCount = maximumModelCount
            self.hashModifier = hashModifier
        }

        /// Creates a fully described relationship for the typed CloudKit
        /// manifest. The legacy variadic initializer remains available for
        /// source compatibility, while this overload records stable names and
        /// the destination without relying on runtime key-path reflection.
        public init(
            name: String,
            originalName: String? = nil,
            options: [Schema.Relationship.Option] = [],
            destination: String,
            deleteRule: Schema.Relationship.DeleteRule = .nullify,
            minimumModelCount: Int? = 0,
            maximumModelCount: Int? = nil,
            inverseName: String? = nil,
            hashModifier: String? = nil
        ) {
            self.name = name
            self.originalName = originalName ?? name
            keypath = nil
            self.options = options
            valueType = Any.self
            self.destination = destination
            self.deleteRule = deleteRule
            self.inverseName = inverseName
            inverseKeyPath = nil
            self.minimumModelCount = minimumModelCount
            self.maximumModelCount = maximumModelCount
            self.hashModifier = hashModifier
        }

        public final var isUnique: Bool {
            options.contains(.unique)
        }

        public final var isAttribute: Bool {
            // This is a Relationship schema node, not an Attribute
            false
        }

        /// Indicates whether the relationship is optional.
        public final var isOptional: Bool {
            minimumModelCount == 0
        }

        public final var isTransient: Bool {
            // TODO: Add .transient option when supported
            false
        }

        public final var debugDescription: String {
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
            name = try container.decode(String.self, forKey: .name)
            originalName = try container.decode(String.self, forKey: .originalName)
            options = try container.decode([Schema.Relationship.Option].self, forKey: .options)
            destination = try container.decode(String.self, forKey: .destination)
            deleteRule = try container.decode(Schema.Relationship.DeleteRule.self, forKey: .deleteRule)
            inverseName = try container.decodeIfPresent(String.self, forKey: .inverseName)
            minimumModelCount = try container.decodeIfPresent(Int.self, forKey: .minimumModelCount)
            maximumModelCount = try container.decodeIfPresent(Int.self, forKey: .maximumModelCount)
            hashModifier = try container.decodeIfPresent(String.self, forKey: .hashModifier)

            // Non-codable runtime-only fields
            keypath = nil
            inverseKeyPath = nil
            valueType = Any.self
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
    public struct Option: Codable, Hashable, CustomDebugStringConvertible {
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
    public enum DeleteRule: String, Codable {
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

extension Schema.Relationship.DeleteRule: Equatable {}

extension Schema.Relationship.DeleteRule: Hashable {}

extension Schema.Relationship.DeleteRule: RawRepresentable {}
