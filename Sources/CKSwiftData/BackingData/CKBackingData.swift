//
//  CKBackingData.swift
//  CKSwiftData
//
//  Created by Valeriy Malishevskyi on 27.10.2025.
//

import CloudKit
import OSLog

private extension Logger {
    static let legacy = Logger(subsystem: "com.stalkermv.CKSwiftData", category: "legacy")
}

/// Record-backed storage used by macro-generated `@CloudModel` declarations.
///
/// This is part of the legacy compatibility layer. New code should use the
/// typed runtime (`CloudModelContainer` and `CloudModelContext`).
final class CKBackingData<T: CloudKitModel>: BackingData {
    private enum AnyCachedRelationship: Hashable {
        case single(AnyCloudKitModel)
        case collection([AnyCloudKitModel])

        func models<Model: CloudKitModel>(_ modelType: Model.Type) -> [Model] {
            switch self {
            case let .single(model):
                (model.boxed as? Model).map { [$0] } ?? []
            case let .collection(models):
                models.compactMap { $0.boxed as? Model }
            }
        }
    }

    typealias Model = T

    var recordID: CKRecord.ID { record.recordID }
    var record: CKRecord
    var relatedBackingData: [String: Any] = [:]
    /// Boundary values that intentionally have no local CKRecord payload yet,
    /// such as a fetched asset reference awaiting explicit materialization.
    var boundaryValues: [String: CloudRecordValue] = [:]
    private var cachedRelationships: [String: AnyCachedRelationship] = [:]

    var database: CKDatabase?

    convenience init(for modelType: T.Type) {
        self.init(for: modelType, database: nil)
    }

    init(for modelType: Model.Type, database: CKDatabase? = nil) {
        record = CKRecord(recordType: T.recordType)
        self.database = database
    }

    func findProperty<Value>(forKey keyPath: KeyPath<Model, Value>) -> Schema.PropertyMetadata {
        guard let property = T.schemaMetadata[keyPath] else {
            preconditionFailure("Key path \(keyPath) was not found in the schema metadata of \(T.self)")
        }
        return property
    }

    func clearCachedRelationship(_ name: String) {
        cachedRelationships.removeValue(forKey: name)
    }

    func getValue<Value>(forKey keyPath: KeyPath<T, Value>) -> Value
        where Value: Decodable & CKRecordValueProtocol
    {
        let property = findProperty(forKey: keyPath)
        if let property = property.metadata as? Schema.Attribute, property.options.contains(.externalStorage) {
            if let asset = record[property.name] as? CKAsset,
               let fileURL = asset.fileURL,
               let data = try? Data(contentsOf: fileURL),
               let decodedValue = try? JSONDecoder().decode(Value.self, from: data)
            {
                return decodedValue
            } else {
                return requireValue(property.defaultValue, named: property.name)
            }
        }

        if let value = record.storedValue(
            forKey: property.name,
            encrypted: property.isEncryptedAttribute
        ) as? CKRecordValueProtocol {
            return requireValue(value, named: property.name)
        } else {
            return requireValue(property.defaultValue, named: property.name)
        }
    }

    func getValue<Value>(forKey keyPath: KeyPath<T, Value?>) -> Value? where Value: CKRecordValueProtocol, Value: Decodable {
        let property = findProperty(forKey: keyPath)
        if let value = record.storedValue(
            forKey: property.name,
            encrypted: property.isEncryptedAttribute
        ) as? CKRecordValueProtocol {
            return value as? Value
        } else {
            return nil
        }
    }

    func getValue<Value>(forKey keyPath: KeyPath<T, Value?>) -> Value?
        where Value: CloudKitModel
    {
        let property = findProperty(forKey: keyPath)
        guard record[property.name] as? CKRecord.Reference != nil else {
            return property.defaultValue as? Value
        }

        // Prefer cached relationship if available
        if let cached = cachedRelationships[property.name]?.models(Value.self).first {
            return cached
        }

        // Fallback to related backing data snapshot
        if let backingData = relatedBackingData[property.name] as? CKBackingData<Value> {
            return Value(backingData: backingData)
        } else if let record = relatedBackingData[property.name] as? CKRecord {
            let bd = CKBackingData<Value>(for: Value.self, database: database)
            bd.record = record
            return Value(backingData: bd)
        }

        return nil
    }

    func getValue<Value, OtherModel>(forKey keyPath: KeyPath<T, Value>) -> Value
        where Value: RelationshipCollection, OtherModel == Value.PersistentElement
    {
        let property = findProperty(forKey: keyPath)

        // Prefer the cached collection if it is available. Arrays are kept in
        // declaration/reference order; a Set would make a getter nondeterministic.
        if let cachedModels = cachedRelationships[property.name]?.models(OtherModel.self), !cachedModels.isEmpty {
            return cachedModels as? Value ?? (property.defaultValue as? Value ?? preconditionFailureValue(property.name))
        }

        // Build from related backing data if it matches the record references
        if let references = record[property.name] as? [CKRecord.Reference],
           let stored = relatedBackingData[property.name] as? [String: Any]
        {
            // Preserve order according to references
            let ordered: [OtherModel] = references.compactMap { ref in
                let key = ref.recordID.recordName
                if let bd = stored[key] as? any BackingData<OtherModel> {
                    return OtherModel(backingData: bd)
                } else if let rec = stored[key] as? CKRecord {
                    let bd = CKBackingData<OtherModel>(for: OtherModel.self, database: database)
                    bd.record = rec
                    return OtherModel(backingData: bd)
                } else {
                    return nil
                }
            }
            return ordered as? Value ?? (property.defaultValue as? Value ?? preconditionFailureValue(property.name))
        }

        // No data available → return default value
        return property.defaultValue as? Value ?? preconditionFailureValue(property.name)
    }

    func setValue<Value>(forKey keyPath: KeyPath<T, Value>, to newValue: Value)
        where Value: Encodable & CKRecordValueProtocol
    {
        let property = findProperty(forKey: keyPath)
        if let property = property.metadata as? Schema.Attribute, property.options.contains(.externalStorage) {
            do {
                record[property.name] = try CKAsset(encodable: newValue, fileName: property.name, fileExtension: "data")
            } catch {
                preconditionFailure("Could not stage asset for property '\(property.name)' of \(T.self): \(error)")
            }
        } else {
            record.setStoredValue(
                newValue,
                forKey: property.name,
                encrypted: property.isEncryptedAttribute
            )
        }
        boundaryValues.removeValue(forKey: property.name)
    }

    func setValue<Value>(forKey keyPath: KeyPath<T, Value?>, to newValue: Value?) where Value: CKRecordValueProtocol, Value: Encodable {
        let property = findProperty(forKey: keyPath)
        record.setStoredValue(
            newValue,
            forKey: property.name,
            encrypted: property.isEncryptedAttribute
        )
        boundaryValues.removeValue(forKey: property.name)
    }

    func setValue<Value>(forKey keyPath: KeyPath<T, Value?>, to newValue: Value?)
        where Value: CloudKitModel
    {
        let property = findProperty(forKey: keyPath)
        let relation = property.metadata as? Schema.Relationship
        let storedBacking = relatedBackingData[property.name] as? CKBackingData<Value>
        let stored = storedBacking.map { Value(backingData: $0) }

        if let relation, let stored {
            updateInverseRelationship(for: stored, relation: relation, adding: false)
        }

        if let newValue {
            let reference = CKRecord.Reference(
                recordID: newValue.recordID,
                action: relation?.referenceAction ?? .none
            )

            record[property.name] = reference
            relatedBackingData[property.name] = newValue.persistentBackingData
            boundaryValues.removeValue(forKey: property.name)
            cachedRelationships[property.name] = .single(AnyCloudKitModel(newValue))

            if let relation {
                updateInverseRelationship(for: newValue, relation: relation, adding: true)
            }
        } else {
            record[property.name] = nil
            relatedBackingData.removeValue(forKey: property.name)
            clearCachedRelationship(property.name)
            boundaryValues.removeValue(forKey: property.name)
        }
    }

    func setValue<Value, OtherModel>(forKey keyPath: KeyPath<T, Value>, to newValue: Value)
        where Value: RelationshipCollection, OtherModel == Value.PersistentElement
    {
        let property = findProperty(forKey: keyPath)
        let relation = property.metadata as? Schema.Relationship

        let oldReferences = record[property.name] as? [CKRecord.Reference] ?? []
        let arrayValue = newValue as? [OtherModel] ?? []

        if let relation {
            let newIDs = Set(arrayValue.map(\.recordID))
            for reference in oldReferences where newIDs.contains(reference.recordID) == false {
                if let old = relatedBackingData[property.name] as? [String: Any],
                   let oldBacking = old[reference.recordID.recordName] as? CKBackingData<OtherModel>
                {
                    updateInverseRelationship(
                        for: OtherModel(backingData: oldBacking),
                        relation: relation,
                        adding: false
                    )
                }
            }
        }

        var references: [CKRecord.Reference] = []
        var relatedData: [String: Any] = [:]
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
        boundaryValues.removeValue(forKey: property.name)

        let cachedModels = arrayValue.map { AnyCloudKitModel($0) }
        cachedRelationships[property.name] = .collection(cachedModels)

        if let relation {
            for model in arrayValue {
                updateInverseRelationship(for: model, relation: relation, adding: true)
            }
        }
    }

    private func preconditionFailureValue<Value>(_ propertyName: String) -> Value {
        preconditionFailure("Missing default value for relationship \(propertyName) of \(T.self)")
    }

    /// Casts a stored or default value to the property's declared type, and
    /// stops with a descriptive message when the types do not match.
    private func requireValue<Value>(_ value: Any?, named propertyName: String) -> Value {
        guard let typed = value as? Value else {
            let actual = value.map { String(describing: type(of: $0)) } ?? "nil"
            preconditionFailure(
                "Property '\(propertyName)' of \(T.self) expected a value of type \(Value.self) but found \(actual)"
            )
        }
        return typed
    }
}

// MARK: - Async relationship loading

extension CKBackingData {
    func loadRelationship<Value>(forKey keyPath: KeyPath<T, Value?>) async throws -> Value?
        where Value: CloudKitModel
    {
        let property = findProperty(forKey: keyPath)

        // If already available via sync path, return it
        if let existing = getValue(forKey: keyPath) { return existing }

        guard let reference = record[property.name] as? CKRecord.Reference,
              let database else { return nil }

        let ids = [reference.recordID]
        let query = CKQuery(recordType: Value.recordType, predicate: NSPredicate(format: "recordID IN %@", ids))
        let (fetched, _) = try await database.records(of: Value.self, matching: query)
        guard let model = fetched.first else { return nil }

        // Update caches
        relatedBackingData[property.name] = model.persistentBackingData
        cachedRelationships[property.name] = .single(AnyCloudKitModel(model))
        return model
    }

    func loadRelationship<Value, OtherModel>(forKey keyPath: KeyPath<T, Value>) async throws -> Value
        where Value: RelationshipCollection, OtherModel == Value.PersistentElement
    {
        let property = findProperty(forKey: keyPath)

        // If already available via sync path or cache, return it
        let current: Value = getValue(forKey: keyPath)
        if (current as? [OtherModel])?.isEmpty == false { return current }

        guard let references = record[property.name] as? [CKRecord.Reference],
              let database, !references.isEmpty
        else {
            return current
        }

        let ids = references.map(\.recordID)
        let query = CKQuery(recordType: OtherModel.recordType, predicate: NSPredicate(format: "recordID IN %@", ids))
        let (fetched, _) = try await database.records(of: OtherModel.self, matching: query)

        // Order according to references
        let mapByName = Dictionary(uniqueKeysWithValues: fetched.map { ($0.recordID.recordName, $0) })
        let ordered: [OtherModel] = references.compactMap { mapByName[$0.recordID.recordName] }

        // Update caches and related backing data snapshot
        var related: [String: Any] = [:]
        for model in ordered {
            related[model.recordID.recordName] = model.persistentBackingData
        }
        relatedBackingData[property.name] = related
        let cached = ordered.map { AnyCloudKitModel($0) }
        cachedRelationships[property.name] = .collection(cached)

        return ordered as? Value ?? (property.defaultValue as? Value ?? preconditionFailureValue(property.name))
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

extension BackingData {
    var record: CKRecord {
        guard let backingData = self as? CKBackingData<Model> else {
            preconditionFailure(
                "Expected a CKBackingData<\(Model.self)> but found \(type(of: self)); only CKBackingData is supported"
            )
        }
        return backingData.record
    }
}

extension CKDatabase {
    public func save<T: CloudKitModel>(_ model: T) async throws -> T {
        guard let backingData = model.persistentBackingData as? CKBackingData<T> else {
            throw CloudModelRuntimeError.missingBackingData
        }
        // Handle saving related records
        for (_, value) in backingData.relatedBackingData {
            if let relatedBackingData = value as? any BackingData<any CloudKitModel> {
                _ = try await save(relatedBackingData.record)
            }
        }

        let savedRecord = try await save(backingData.record)
        backingData.record = savedRecord
        backingData.database = self
        return T(backingData: backingData)
    }

    public func delete<T: CloudKitModel>(_ model: T) async throws {
        guard let backingData = model.persistentBackingData as? CKBackingData<T> else {
            throw CloudModelRuntimeError.missingBackingData
        }
        try await deleteRecord(withID: backingData.recordID)
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
        let result = try await records(
            matching: query,
            inZoneWith: zoneID,
            desiredKeys: desiredKeys,
            resultsLimit: resultsLimit
        )

        for (id, matchResult) in result.matchResults {
            switch matchResult {
            case let .success(record):
                let backing = CKBackingData<T>(for: T.self, database: self)
                backing.record = record
                decoded.append(T(backingData: backing))
            case let .failure(error):
                Logger.legacy.error("Failed to fetch record \(id.recordName): \(error)")
            }
        }
        return (decoded, result.queryCursor)
    }
}

extension CKAsset {
    /// Encodes `value` to a uniquely named temporary file and wraps it in an
    /// asset. Every call writes to its own directory, so concurrent or repeated
    /// calls with the same `fileName` never overwrite each other.
    convenience init(
        encodable value: some Encodable,
        fileName: String,
        fileExtension: String,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        let data = try encoder.encode(value)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CKSwiftData", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(fileName).\(fileExtension)")
        try data.write(to: fileURL)
        self.init(fileURL: fileURL)
    }
}

extension CKBackingData {
    func preloadAllRelationships() async throws {
        guard let database else { return }
        for property in T.schemaMetadata {
            guard let relationship = property.metadata as? Schema.Relationship else { continue }

            if relationship.isToOneRelationship {
                guard relatedBackingData[relationship.name] == nil,
                      let reference = record[relationship.name] as? CKRecord.Reference else { continue }
                let fetched = try await database.record(for: reference.recordID)
                relatedBackingData[relationship.name] = fetched
                continue
            }

            if let references = record[relationship.name] as? [CKRecord.Reference], !references.isEmpty {
                var current = (relatedBackingData[relationship.name] as? [String: Any]) ?? [:]
                let missing = references.map(\.recordID.recordName).filter { current[$0] == nil }
                if missing.isEmpty { continue }

                // Fetch all referenced records and store as CKRecord map
                let ids = references.map(\.recordID)
                let query = CKQuery(recordType: relationship.destination, predicate: NSPredicate(format: "recordID IN %@", ids))
                let result = try await database.records(matching: query)
                for (rid, match) in result.matchResults {
                    if case let .success(rec) = match {
                        current[rid.recordName] = rec
                    }
                }
                relatedBackingData[relationship.name] = current
            }
        }
    }
}

extension AnyKeyPath {
    var _rootType: Any.Type {
        Self.rootType
    }

    var _valueType: Any.Type {
        Self.valueType
    }
}
