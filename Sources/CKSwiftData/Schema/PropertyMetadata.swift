//
//  PropertyMetadata.swift
//  Mem
//
//  Created by Valeriy Malishevskyi on 31.08.2025.
//

import Foundation

extension Schema {
    public struct PropertyMetadata {
        public let name: String
        public let keypath: AnyKeyPath
        public let defaultValue: Any?
        public let metadata: (any SchemaProperty)?
        
        public init(
            name: String,
            keypath: AnyKeyPath,
            defaultValue: Any? = nil,
            metadata: (any SchemaProperty)? = nil
        ) {
            self.name = name
            self.keypath = keypath
            self.defaultValue = defaultValue
            if var metadata = metadata as? Schema.Relationship {
                metadata.name = name
                metadata.keypath = keypath
                self.metadata = metadata
            } else {
                self.metadata = metadata
            }
        }
    }
}
