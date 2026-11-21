//
//  BackingData.swift
//  CKSwiftData
//
//  Created by Valeriy Malishevskyi on 31.08.2025.
//

import CloudKit

/// Storage behind a macro-generated `@CloudModel` declaration.
///
/// This is part of the legacy compatibility layer. New code should use the
/// typed runtime (`CloudModelContainer` and `CloudModelContext`).
public protocol BackingData<Model> {
    associatedtype Model: CloudKitModel

    init(for modelType: Self.Model.Type)

    var recordID: CKRecord.ID { get }

    // MARK: - Methods for getting values

    func getValue<Value>(forKey: KeyPath<Self.Model, Value>) -> Value
        where Value: Decodable & CKRecordValueProtocol

    func getValue<Value>(forKey: KeyPath<Self.Model, Value?>) -> Value?
        where Value: Decodable & CKRecordValueProtocol

    @_disfavoredOverload
    func getValue<Value>(forKey: KeyPath<Self.Model, Value?>) -> Value?
        where Value: CloudKitModel

    func getValue<Value, OtherModel>(forKey: KeyPath<Self.Model, Value>) -> Value
        where Value: RelationshipCollection, OtherModel == Value.PersistentElement

    // MARK: - Methods for setting values

    func setValue<Value>(forKey: KeyPath<Self.Model, Value>, to newValue: Value)
        where Value: Encodable & CKRecordValueProtocol

    func setValue<Value>(forKey: KeyPath<Self.Model, Value?>, to newValue: Value?)
        where Value: Encodable & CKRecordValueProtocol

    @_disfavoredOverload
    func setValue<Value>(forKey: KeyPath<Self.Model, Value?>, to newValue: Value?)
        where Value: CloudKitModel

    func setValue<Value, OtherModel>(forKey: KeyPath<Self.Model, Value>, to newValue: Value)
        where Value: RelationshipCollection, OtherModel == Value.PersistentElement
}

// MARK: - Async relationship loading

public extension BackingData {
    func loadRelationship<Value>(forKey: KeyPath<Self.Model, Value?>) async throws -> Value?
        where Value: CloudKitModel
    {
        throw CloudModelError.unsupported("relationship loading is not implemented by this backing store")
    }

    func loadRelationship<Value, OtherModel>(forKey: KeyPath<Self.Model, Value>) async throws -> Value
        where Value: RelationshipCollection, OtherModel == Value.PersistentElement
    {
        throw CloudModelError.unsupported("relationship loading is not implemented by this backing store")
    }
}
