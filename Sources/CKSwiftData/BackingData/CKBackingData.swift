//
//  CKBackingData.swift
//  CKSwiftData
//
//  Created by Valeriy Malishevskyi on 27.10.2025.
//

import CloudKit

final class CKBackingData<T: CloudKitModel>: BackingData {
    
    typealias Model = T
    
    var recordID: CKRecord.ID { record.recordID }
    var record: CKRecord
    var relatedBackingData: [String: Any] = [:]
    var cachedRelationships: [String: Any] = [:]
    
    init(for modelType: Model.Type) {
        self.record = CKRecord(recordType: T.recordType)
    }
    
    func findProperty<Value>(forKey keyPath: KeyPath<Model, Value>) -> Schema.PropertyMetadata {
        guard let property = T.schemaMetadata[keyPath] else {
            fatalError("Property not found in schema metadata")
        }
        return property
    }

    func getValue<Value>(forKey keyPath: KeyPath<T, Value>) -> Value
    where Value : Decodable & CKRecordValueProtocol {
        let property = findProperty(forKey: keyPath)
        if let property = property.metadata as? Schema.Attribute, property.options.contains(.externalStorage) {
            if let asset = record[property.name] as? CKAsset,
               let data = try? Data(contentsOf: asset.fileURL!),
               let decodedValue = try? JSONDecoder().decode(Value.self, from: data) {
                return decodedValue
            } else {
                return property.defaultValue as! Value
            }
        }
        
        if let value = record[property.name] as? CKRecordValueProtocol {
            return value as! Value
        } else {
            return property.defaultValue as! Value
        }
    }
    
    func getValue<Value>(forKey keyPath: KeyPath<T, Value?>) -> Value? where Value : CKRecordValueProtocol, Value : Decodable {
        let property = findProperty(forKey: keyPath)
        if let value = record[property.name] as? CKRecordValueProtocol {
            return value as? Value
        } else {
            return nil
        }
    }
    
    func getValue<Value>(forKey keyPath: KeyPath<T, Value?>) -> Value?
    where Value : CloudKitModel {
        let property = findProperty(forKey: keyPath)
        if let reference = record[property.name] as? CKRecord.Reference {
            if let backingData = relatedBackingData[property.name] as? CKBackingData<Value> {
                return Value(backingData: backingData)
            } else {
                return nil
            }
        } else {
            return nil
        }
    }
    
    func getValue<Value, OtherModel>(forKey: KeyPath<T, Value>) -> Value
    where Value : RelationshipCollection, OtherModel == Value.PersistentElement {
        fatalError("Not implemented yet")
    }
    
    func setValue<Value>(forKey keyPath: KeyPath<T, Value>, to newValue: Value)
    where Value : Encodable & CKRecordValueProtocol {
        let property = findProperty(forKey: keyPath)
        if let property = property.metadata as? Schema.Attribute, property.options.contains(.externalStorage) {
            let asset = CKAsset(encodable: newValue, fileName: property.name, fileExtension: "data")
            record[property.name] = asset
        } else {
            record[property.name] = newValue
        }
    }
    
    func setValue<Value>(forKey keyPath: KeyPath<T, Value?>, to newValue: Value?) where Value : CKRecordValueProtocol, Value : Encodable {
        let property = findProperty(forKey: keyPath)
        record[property.name] = newValue
    }
    
    func setValue<Value>(forKey keyPath: KeyPath<T, Value?>, to newValue: Value?)
    where Value : CloudKitModel {
        let property = findProperty(forKey: keyPath)
        let relation = property.metadata as? Schema.Relationship
        if let inverseKeyPath = relation?.inverseKeyPath {
            newValue?.persistentBackingData.setValue(
                forKey: inverseKeyPath as! KeyPath<Value, Model?>,
                to: Model(backingData: self)
            )
        } else if let newValue {
            let reference = CKRecord.Reference(
                recordID: newValue.recordID,
                action: relation?.referenceAction ?? .none
            )
            record[property.name] = reference
            relatedBackingData[property.name] = newValue.persistentBackingData
        } else {
            record[property.name] = nil
        }
    }
    
    func setValue<Value, OtherModel>(forKey keyPath: KeyPath<T, Value>, to newValue: Value)
    where Value : RelationshipCollection, OtherModel == Value.PersistentElement {
        let property = findProperty(forKey: keyPath)
        let relation = property.metadata as? Schema.Relationship
        
        var references: [CKRecord.Reference] = []
        var relatedData: [String: Any] = [:]
        var arrayValue = newValue as? [OtherModel] ?? []
        
        for model in arrayValue {
            let reference = CKRecord.Reference(
                recordID: model.recordID,
                action: relation?.referenceAction ?? .none
            )
            references.append(reference)
            relatedData[model.recordID.recordName] = model.persistentBackingData
        }
        
        record[property.name] = references as CKRecordValueProtocol
        relatedBackingData[property.name] = relatedData
    }
}

extension Schema.Relationship {
    var referenceAction: CKRecord.ReferenceAction {
        switch deleteRule {
        case .cascade:
            return .deleteSelf
        case .nullify:
            return .none
        case .deny:
            return .none
        case .noAction:
            return .none
        @unknown default:
            return .none
        }
    }
}

extension CKDatabase {
    public func save<T: CloudKitModel>(_ model: T) async throws -> T {
        let backingData = model.persistentBackingData as! CKBackingData<T>
        // TODO: Handle saving related records if needed
        let savedRecord = try await self.save(backingData.record)
        backingData.record = savedRecord
        return T(backingData: backingData)
    }
    
    public func delete<T: CloudKitModel>(_ model: T) async throws {
        let backingData = model.persistentBackingData as! CKBackingData<T>
        try await self.deleteRecord(withID: backingData.recordID)
    }

}

extension CKQuery {
    /// Use `NSPredicate(value: true)` if you want to query for all records of a given type.
    @available(swift 4.2)
    public convenience init<T: CloudKitModel>(recordType: T.Type, predicate: NSPredicate) {
        self.init(recordType: T.recordType, predicate: predicate)
    }
}

extension CKDatabase {
    public func records<T: CloudKitModel>(
        of type: T.Type,
        matching query: CKQuery,
        inZoneWith zoneID: CKRecordZone.ID? = nil,
        desiredKeys: [CKRecord.FieldKey]? = nil,
        resultsLimit: Int = CKQueryOperation.maximumResults
    ) async throws -> (records: [T], queryCursor: CKQueryOperation.Cursor?) {
        var decoded: [T] = []
        let result = try await self.records(matching: query)
        
        for (id, matchResult) in result.matchResults {
            switch matchResult {
            case .success(let record):
                let backing = CKBackingData<T>(for: T.self)
                backing.record = record
                decoded.append(T(backingData: backing))
            case .failure(let error):
                print("⚠️ Failed to fetch record \(id.recordName): \(error)")
            }
        }
        return (decoded, result.queryCursor)
    }
}

extension CKAsset {
    convenience init(encodable value: some Encodable, fileName: String, fileExtension: String, encoder: JSONEncoder = JSONEncoder()) {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("\(fileName).\(fileExtension)")
        let data = try! encoder.encode(value)
        try! data.write(to: fileURL)
        self.init(fileURL: fileURL)
    }
}
