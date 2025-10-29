//
//  Created by Valeriy Malishevskyi on 07.02.2024.
//

import Foundation

extension Schema {
    
    public class Attribute : SchemaProperty, CustomDebugStringConvertible {

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
            self.name = originalName ?? ""
            self.originalName = originalName ?? ""
            self.options = options
            self.valueType = Any.self
            self.isOptional = false
            self.hashModifier = hashModifier
        }
        
        public init(
            name: String,
            originalName: String? = nil,
            options: [Schema.Attribute.Option] = [],
            valueType: Any.Type,
            defaultValue: Any? = nil,
            hashModifier: String? = nil
        ) {
            self.name = name
            self.originalName = originalName ?? name
            self.options = options
            self.valueType = valueType
            self.defaultValue = defaultValue
            self.isOptional = defaultValue != nil
            self.hashModifier = hashModifier
        }
        
        public var isAttribute: Bool { 
            return true
        }
        
        public var isRelationship: Bool { 
            return false
        }
        
        public var isTransient: Bool { 
            return false
        }
        
        public var isUnique: Bool { 
            return false
        }
        
        public var isTransformable: Bool { 
            return false
        }

        public var debugDescription: String {
            """
            Schema.Attribute(
                name: \(self.name),
                originalName: \(self.originalName),
                options: \(self.options),
                valueType: \(self.valueType),
                defaultValue: \(self.defaultValue ?? "nil"),
                isOptional: \(self.isOptional),
                hashModifier: \(self.hashModifier ?? "nil")
            )
            """
        }
        
        // MARK: Codable
        
        public required init(from decoder: Decoder) throws {
            fatalError("Not implemented")
        }
        
        public func encode(to encoder: Encoder) throws {
            fatalError("Not implemented")
        }
    }
}

extension Schema.Attribute : Codable { }

extension Schema.Attribute : Hashable {
    public static func == (lhs: Schema.Attribute, rhs: Schema.Attribute) -> Bool {
        return lhs.name == rhs.name
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.name)
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
            return Schema.Attribute.Option(optionType: .unique)
        }
        
        /// Transforms the property's value between an in-memory form and a persisted form.
        public static func transformable(by transformerType: ValueTransformer.Type) -> Schema.Attribute.Option {
            return Schema.Attribute.Option(optionType: .transformable)
        }
        
        public static func transformable(by transformerName: String) -> Schema.Attribute.Option {
            return Schema.Attribute.Option(optionType: .transformable)
        }
        
        /// Stores the property's value as binary data adjacent to the model storage.
        public static var externalStorage: Schema.Attribute.Option {
            return Schema.Attribute.Option(optionType: .externalStorage)
        }
        
        /// Stores the property's value in an encrypted form.
        public static var allowsCloudEncryption: Schema.Attribute.Option {
            return Schema.Attribute.Option(optionType: .allowsCloudEncryption)
        }
        
        /// Preserves the property's value in the persistent history when the context deletes the owning model.
        public static var preserveValueOnDeletion: Schema.Attribute.Option {
            return Schema.Attribute.Option(optionType: .preserveValueOnDeletion)
        }
        
        /// Track changes to this property but do not persist
        public static var ephemeral: Schema.Attribute.Option {
            return Schema.Attribute.Option(optionType: .ephemeral)
        }
        
        /// Indexes the property's value so it can appear in Spotlight search results.
        public static var spotlight: Schema.Attribute.Option {
            return Schema.Attribute.Option(optionType: .spotlight)
        }
    }
}

extension Schema.Attribute.Option : Codable { }

extension Schema.Attribute.Option : Hashable { }

extension Schema.Attribute.Option : CustomDebugStringConvertible {
    public var debugDescription: String {
        """
        Schema.Attribute.Option(
            name: \(self.optionType)
        )
        """
    }
}
