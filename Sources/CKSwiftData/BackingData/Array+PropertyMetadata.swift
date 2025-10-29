//
//  Array+PropertyMetadata.swift
//  Mem
//
//  Created by Valeriy Malishevskyi on 01.09.2025.
//

extension Array where Element == Schema.PropertyMetadata {
    /// Find the property metadata by matching the keyPath
    subscript(keyPath: AnyKeyPath) -> Schema.PropertyMetadata? {
        guard let e = first(where: { $0.keypath == keyPath }) else {
            return nil
        }
        return e
    }
    
    subscript(name: String) -> Schema.PropertyMetadata? {
        guard let e = first(where: { $0.name == name }) else {
            return nil
        }
        return e
    }
}
