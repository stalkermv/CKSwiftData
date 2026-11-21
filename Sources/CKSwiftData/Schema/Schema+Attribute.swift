//
//  Created by Valeriy Malishevskyi on 07.02.2024.
//

import Foundation

extension Schema {
    public class Attribute: SchemaProperty, CustomDebugStringConvertible {
        public var name: String

        public var originalName: String

        public var options: [Schema.Attribute.Option]

        public var valueType: Any.Type

        public var defaultValue: Any?

        public var isOptional: Bool

        public var hashModifier: String?

        public init(
            _ options: Schema.Attribute.Option...,
            originalName: String? = nil,
            hashModifier: String? = nil
        ) {
            name = originalName ?? ""
            self.originalName = originalName ?? ""
            self.options = options
            valueType = Any.self
            isOptional = false
            self.hashModifier = hashModifier
        }

        public init(
            name: String,
            originalName: String? = nil,
            options: [Schema.Attribute.Option] = [],
            valueType: Any.Type,
            defaultValue: Any? = nil,
            isOptional: Bool? = nil,
            hashModifier: String? = nil
        ) {
            self.name = name
            self.originalName = originalName ?? name
            self.options = options
            self.valueType = valueType
            self.defaultValue = defaultValue
            self.isOptional = isOptional ?? (defaultValue != nil)
            self.hashModifier = hashModifier
        }

        public var isAttribute: Bool {
            true
        }

        public var isRelationship: Bool {
            false
        }

        public var isTransient: Bool {
            false
        }

        public var isUnique: Bool {
            false
        }

        public var isTransformable: Bool {
            false
        }

        public var debugDescription: String {
            """
            Schema.Attribute(
                name: \(name),
                originalName: \(originalName),
                options: \(options),
                valueType: \(valueType),
                defaultValue: \(defaultValue ?? "nil"),
                isOptional: \(isOptional),
                hashModifier: \(hashModifier ?? "nil")
            )
            """
        }

        // MARK: Codable

        /// Runtime-only values (`valueType` and `defaultValue`) are deliberately
        /// not serialized. The typed `CloudAttributeSchema` is the 1.0 manifest
        /// representation; this legacy class only preserves its stable metadata.
        private enum CodingKeys: String, CodingKey {
            case name
            case originalName
            case options
            case isOptional
            case hashModifier
        }

        public required init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            originalName = try container.decode(String.self, forKey: .originalName)
            options = try container.decode([Schema.Attribute.Option].self, forKey: .options)
            isOptional = try container.decode(Bool.self, forKey: .isOptional)
            hashModifier = try container.decodeIfPresent(String.self, forKey: .hashModifier)
            valueType = Any.self
            defaultValue = nil
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(originalName, forKey: .originalName)
            try container.encode(options, forKey: .options)
            try container.encode(isOptional, forKey: .isOptional)
            try container.encodeIfPresent(hashModifier, forKey: .hashModifier)
        }
    }
}

extension Schema.Attribute: Codable {}

extension Schema.Attribute: Hashable {
    public static func == (lhs: Schema.Attribute, rhs: Schema.Attribute) -> Bool {
        lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

// MARK: - Schema.Attribute.Option

extension Schema.Attribute {
    public struct Option {
        enum OptionType: String, Codable {
            case indexed
            case unique
            case transformable
            case externalStorage
            case allowsCloudEncryption
            case preserveValueOnDeletion
            case ephemeral
            case spotlight
        }

        var optionType: OptionType

        /// Ensures the property's value is unique across all models of the same type.
        public static var unique: Schema.Attribute.Option {
            Schema.Attribute.Option(optionType: .unique)
        }

        /// Transforms the property's value between an in-memory form and a persisted form.
        public static func transformable(by transformerType: ValueTransformer.Type) -> Schema.Attribute.Option {
            Schema.Attribute.Option(optionType: .transformable)
        }

        public static func transformable(by transformerName: String) -> Schema.Attribute.Option {
            Schema.Attribute.Option(optionType: .transformable)
        }

        /// Stores the property's value as binary data adjacent to the model storage.
        public static var externalStorage: Schema.Attribute.Option {
            Schema.Attribute.Option(optionType: .externalStorage)
        }

        /// Stores the property's value in an encrypted form.
        public static var allowsCloudEncryption: Schema.Attribute.Option {
            Schema.Attribute.Option(optionType: .allowsCloudEncryption)
        }

        /// Preserves the property's value in the persistent history when the context deletes the owning model.
        public static var preserveValueOnDeletion: Schema.Attribute.Option {
            Schema.Attribute.Option(optionType: .preserveValueOnDeletion)
        }

        /// Track changes to this property but do not persist
        public static var ephemeral: Schema.Attribute.Option {
            Schema.Attribute.Option(optionType: .ephemeral)
        }

        /// Indexes the property's value so it can appear in Spotlight search results.
        public static var spotlight: Schema.Attribute.Option {
            Schema.Attribute.Option(optionType: .spotlight)
        }
    }
}

extension Schema.Attribute.Option: Codable {}

extension Schema.Attribute.Option: Hashable {}

extension Schema.Attribute.Option: CustomDebugStringConvertible {
    public var debugDescription: String {
        """
        Schema.Attribute.Option(
            name: \(optionType)
        )
        """
    }
}
