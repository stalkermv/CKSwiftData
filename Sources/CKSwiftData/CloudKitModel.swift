//
//  CloudKitModel.swift
//  CKSwiftData
//
//  Created by Valeriy Malishevskyi on 27.10.2025.
//

import CloudKit

public protocol CloudKitModel: Identifiable, AnyObject {
    var recordID: CKRecord.ID { get }
    var recordChangeTag: String? { get }
    var creatorUserRecordID: CKRecord.ID? { get }
    var creationDate: Date? { get }
    var lastModifiedUserRecordID: CKRecord.ID? { get }
    var modificationDate: Date? { get }

    var persistentBackingData: any BackingData<Self> { get set }
    init(backingData: any BackingData<Self>)
    static var schemaMetadata: [Schema.PropertyMetadata] { get }
}

public extension CloudKitModel {
    static var recordType: String {
        String(describing: Self.self)
    }

    var recordChangeTag: String? {
        (persistentBackingData as? CKBackingData<Self>)?.record.recordChangeTag
    }

    var recordID: CKRecord.ID {
        persistentBackingData.recordID
    }

    var creatorUserRecordID: CKRecord.ID? {
        (persistentBackingData as? CKBackingData<Self>)?.record.creatorUserRecordID
    }

    var creationDate: Date? {
        (persistentBackingData as? CKBackingData<Self>)?.record.creationDate
    }

    var lastModifiedUserRecordID: CKRecord.ID? {
        (persistentBackingData as? CKBackingData<Self>)?.record.lastModifiedUserRecordID
    }

    var modificationDate: Date? {
        (persistentBackingData as? CKBackingData<Self>)?.record.modificationDate
    }

    static func createBackingData() -> any BackingData<Self> {
        CKBackingData<Self>(for: Self.self)
    }
}

extension CloudKitModel {
    @inlinable public func getValue<Value>(forKey: KeyPath<Self, Value>) -> Value
        where Value: Decodable & CKRecordValueProtocol
    {
        persistentBackingData.getValue(forKey: forKey)
    }

    @inlinable public func getValue<Value>(forKey: KeyPath<Self, Value?>) -> Value?
        where Value: Decodable & CKRecordValueProtocol
    {
        persistentBackingData.getValue(forKey: forKey)
    }

    @inlinable public func setValue<Value>(forKey: KeyPath<Self, Value>, to newValue: Value) where Value: Encodable & CKRecordValueProtocol {
        persistentBackingData.setValue(forKey: forKey, to: newValue)
    }

    @inlinable public func setValue<Value>(forKey: KeyPath<Self, Value?>, to newValue: Value?) where Value: Encodable & CKRecordValueProtocol {
        persistentBackingData.setValue(forKey: forKey, to: newValue)
    }

    // MARK: - Async relationship loading

    @inlinable public func loadRelationship<Value>(forKey: KeyPath<Self, Value?>) async throws -> Value?
        where Value: CloudKitModel
    {
        try await persistentBackingData.loadRelationship(forKey: forKey)
    }

    @inlinable public func loadRelationship<Value, OtherModel>(forKey: KeyPath<Self, Value>) async throws -> Value
        where Value: RelationshipCollection, OtherModel == Value.PersistentElement
    {
        try await persistentBackingData.loadRelationship(forKey: forKey)
    }
}
