//
//  BackingData.swift
//  Mem
//
//  Created by Valeriy Malishevskyi on 31.08.2025.
//

import CloudKit

public protocol BackingData<Model> {
    
    associatedtype Model : CloudKitModel
    
    init(for modelType: Self.Model.Type)
    
    var recordID: CKRecord.ID { get }
    
    // MARK: - Methods for getting values
    
    func getValue<Value>(forKey: KeyPath<Self.Model, Value>) -> Value
    where Value : Decodable & CKRecordValueProtocol
    
    func getValue<Value>(forKey: KeyPath<Self.Model, Value?>) -> Value?
    where Value : Decodable & CKRecordValueProtocol
    
    @_disfavoredOverload
    func getValue<Value>(forKey: KeyPath<Self.Model, Value?>) -> Value?
    where Value : CloudKitModel
    
    func getValue<Value, OtherModel>(forKey: KeyPath<Self.Model, Value>) -> Value
    where Value : RelationshipCollection, OtherModel == Value.PersistentElement
    
    // MARK: - Methods for setting values
    
    func setValue<Value>(forKey: KeyPath<Self.Model, Value>, to newValue: Value)
    where Value : Encodable & CKRecordValueProtocol
    
    func setValue<Value>(forKey: KeyPath<Self.Model, Value?>, to newValue: Value?)
    where Value : Encodable & CKRecordValueProtocol
    
    @_disfavoredOverload
    func setValue<Value>(forKey: KeyPath<Self.Model, Value?>, to newValue: Value?)
    where Value : CloudKitModel
    
    func setValue<Value, OtherModel>(forKey: KeyPath<Self.Model, Value>, to newValue: Value)
    where Value : RelationshipCollection, OtherModel == Value.PersistentElement
}
