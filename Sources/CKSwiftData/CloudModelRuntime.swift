import CloudKit
import Foundation
import os

private enum CloudModelRuntimeCache {
    // Only macro-generated models opt into this cache. Their identity and
    // schema declarations are deterministic type-level values. Keep the cache
    // process-local and keyed by the metatype so every record snapshot does
    // not repeat identifier validation or metadata parsing.
    private static let identifiers = OSAllocatedUnfairLock(
        initialState: [ObjectIdentifier: CloudModelIdentifier]()
    )
    private static let schemas = OSAllocatedUnfairLock(
        initialState: [ObjectIdentifier: CloudModelSchema]()
    )

    static func identifier(
        for modelType: ObjectIdentifier,
        build: () throws -> CloudModelIdentifier
    ) throws -> CloudModelIdentifier {
        if let cached = identifiers.withLock({ $0[modelType] }) {
            return cached
        }
        // Build outside the lock; concurrent first callers may do duplicate
        // pure work, while the commit below still publishes one canonical value.
        let identifier = try build()
        return identifiers.withLock { cache in
            if let cached = cache[modelType] {
                return cached
            }
            cache[modelType] = identifier
            return identifier
        }
    }

    static func schema(
        for modelType: ObjectIdentifier,
        build: () throws -> CloudModelSchema
    ) throws -> CloudModelSchema {
        if let cached = schemas.withLock({ $0[modelType] }) {
            return cached
        }
        // See identifier(_:build:): avoid holding the lock while reading the
        // model declaration and constructing its validated schema.
        let schema = try build()
        return schemas.withLock { cache in
            if let cached = cache[modelType] {
                return cached
            }
            cache[modelType] = schema
            return schema
        }
    }
}

/// Errors raised while bridging a model declaration to the typed record
/// boundary. The error identifies unsupported or incomplete declarations
/// instead of silently dropping fields.
public enum CloudModelRuntimeError: Error, Codable, Equatable, Hashable, Sendable {
    case unsupportedField(CloudFieldIdentifier, reason: String)
    case unknownField(CloudFieldIdentifier)
    case invalidSnapshot(CloudRecordIdentifier, reason: String)
    case missingBackingData
    case modelIdentifierMismatch(
        expected: CloudModelIdentifier,
        actual: CloudModelIdentifier
    )
}

/// A model declaration that can be materialized by `CloudModelContext`.
///
/// The protocol intentionally exposes immutable boundary operations instead of
/// `Any`-typed property reflection. Macro-generated `CloudKitModel` classes get
/// the default bridge below; custom model types may implement the same contract
/// directly.
public protocol CloudPersistentModel: AnyObject {
    static var cloudModelName: String { get }
    static var cloudRecordType: String { get }
    static var cloudSchemaVersion: Int { get }

    /// Whether the model supplies deterministic type-level metadata that can
    /// be cached for the lifetime of the process. Custom conformers default to
    /// `false` so dynamic declarations are never frozen by the runtime cache.
    static var cloudModelRuntimeMetadataIsStable: Bool { get }

    static func cloudModelIdentifier() throws -> CloudModelIdentifier
    static func cloudModelSchema() throws -> CloudModelSchema
    static func makeCloudModel(
        from snapshot: CloudRecordSnapshot,
        in zone: CloudZoneIdentifier
    ) throws -> Self

    func cloudRecordIdentifier(in zone: CloudZoneIdentifier) throws -> CloudRecordIdentifier
    func cloudRecordSnapshot(in zone: CloudZoneIdentifier) throws -> CloudRecordSnapshot
    func applyCloudRecordSnapshot(_ snapshot: CloudRecordSnapshot) throws
}

public extension CloudPersistentModel {
    static var cloudModelName: String { String(describing: Self.self) }
    static var cloudRecordType: String { cloudModelName }
    static var cloudSchemaVersion: Int { 1 }
    static var cloudModelRuntimeMetadataIsStable: Bool { false }

    static func cloudModelIdentifier() throws -> CloudModelIdentifier {
        let build = {
            try CloudModelIdentifier(cloudRecordType)
        }
        guard cloudModelRuntimeMetadataIsStable else {
            return try build()
        }
        return try CloudModelRuntimeCache.identifier(for: ObjectIdentifier(Self.self), build: build)
    }
}

/// The default bridge for the prototype's `CloudKitModel` declaration. It is
/// deliberately kept in a separate extension so the 1.0 runtime can replace
/// the old `BackingData` implementation without changing the context API.
public extension CloudPersistentModel where Self: CloudKitModel {
    static var cloudRecordType: String { recordType }

    static func cloudModelSchema() throws -> CloudModelSchema {
        let build = {
            let modelID = try cloudModelIdentifier()
            let fields = try schemaMetadata.map { property -> CloudFieldSchema in
                guard let metadata = property.metadata else {
                    let fieldID = try CloudFieldIdentifier(property.name)
                    throw CloudModelRuntimeError.unsupportedField(
                        fieldID,
                        reason: "the property has no typed schema metadata"
                    )
                }

                if let attribute = metadata as? Schema.Attribute {
                    let fieldID = try CloudFieldIdentifier(property.name)
                    let recordName = try CloudFieldIdentifier(property.name)
                    let renamedFrom: CloudFieldIdentifier? = if attribute.originalName.isEmpty || attribute.originalName == property.name {
                        nil
                    } else {
                        try CloudFieldIdentifier(attribute.originalName)
                    }
                    let kind: CloudAttributeKind = attribute.options.contains(.externalStorage)
                        ? .asset
                        : .scalar
                    let optionality: CloudFieldOptionality = attribute.isOptional
                        ? .optional
                        : .required
                    return try .attribute(
                        CloudAttributeSchema(
                            id: fieldID,
                            recordName: recordName,
                            kind: kind,
                            optionality: optionality,
                            renamedFrom: renamedFrom,
                            encrypted: attribute.options.contains(.allowsCloudEncryption),
                            externalStorage: attribute.options.contains(.externalStorage)
                        )
                    )
                }

                guard let relationship = metadata as? Schema.Relationship else {
                    let fieldID = try CloudFieldIdentifier(property.name)
                    throw CloudModelRuntimeError.unsupportedField(
                        fieldID,
                        reason: "unsupported schema metadata"
                    )
                }
                guard relationship.destination.isEmpty == false else {
                    let fieldID = try CloudFieldIdentifier(property.name)
                    throw CloudModelRuntimeError.unsupportedField(
                        fieldID,
                        reason: "relationship destination is not declared"
                    )
                }
                let destination = try CloudModelIdentifier(relationship.destination)
                let inverse: CloudFieldIdentifier? = if let inverseName = relationship.inverseName {
                    try CloudFieldIdentifier(inverseName)
                } else {
                    nil
                }
                let cardinality: CloudRelationshipCardinality = if relationship.isToOneRelationship {
                    .toOne(required: relationship.isOptional == false)
                } else {
                    try .init(
                        toManyMinimum: relationship.minimumModelCount ?? 0,
                        maximum: relationship.maximumModelCount,
                        ordering: .stable
                    )
                }
                let deleteRule: CloudDeleteRule = switch relationship.deleteRule {
                case .noAction: .noAction
                case .nullify: .nullify
                case .cascade: .cascade
                case .deny: .deny
                }
                return try .relationship(
                    CloudRelationshipSchema(
                        id: CloudFieldIdentifier(property.name),
                        recordName: CloudFieldIdentifier(property.name),
                        destination: destination,
                        inverse: inverse,
                        cardinality: cardinality,
                        deleteRule: deleteRule
                    )
                )
            }
            return try CloudModelSchema(
                id: modelID,
                recordType: CloudModelIdentifier(cloudRecordType),
                version: cloudSchemaVersion,
                fields: fields
            )
        }
        guard Self.cloudModelRuntimeMetadataIsStable else {
            return try build()
        }
        return try CloudModelRuntimeCache.schema(for: ObjectIdentifier(Self.self), build: build)
    }

    func cloudRecordIdentifier(in zone: CloudZoneIdentifier) throws -> CloudRecordIdentifier {
        try CloudRecordIdentifier(recordName: recordID.recordName, zone: zone)
    }

    func cloudRecordSnapshot(in zone: CloudZoneIdentifier) throws -> CloudRecordSnapshot {
        guard let backing = persistentBackingData as? CKBackingData<Self> else {
            throw CloudModelRuntimeError.missingBackingData
        }
        let modelID = try Self.cloudModelIdentifier()
        let recordID = try CloudRecordIdentifier(recordName: backing.record.recordID.recordName, zone: zone)
        let modelSchema = try Self.cloudModelSchema()
        var fields = [CloudFieldIdentifier: CloudRecordValue]()
        for field in modelSchema.fields {
            if let rawValue = backing.record[field.recordName.rawValue] {
                fields[field.id] = try CloudRecordValue(
                    cloudKitValue: rawValue,
                    fieldID: field.id,
                    expectedKind: field.expectedCloudRecordValueKind,
                    zoneOverride: zone
                )
            } else if let boundaryValue = backing.boundaryValues[field.recordName.rawValue] {
                fields[field.id] = boundaryValue
            }
        }
        return try CloudRecordSnapshot(
            id: recordID,
            modelID: modelID,
            changeTag: backing.record.recordChangeTag,
            fields: fields
        )
    }

    func applyCloudRecordSnapshot(_ snapshot: CloudRecordSnapshot) throws {
        let expected = try Self.cloudModelIdentifier()
        guard snapshot.modelID == expected else {
            throw CloudModelRuntimeError.modelIdentifierMismatch(
                expected: expected,
                actual: snapshot.modelID
            )
        }
        guard let backing = persistentBackingData as? CKBackingData<Self> else {
            throw CloudModelRuntimeError.missingBackingData
        }
        let modelSchema = try Self.cloudModelSchema()
        let fieldsByID = Dictionary(uniqueKeysWithValues: modelSchema.fields.map { ($0.id, $0) })
        for fieldID in snapshot.fields.keys where fieldsByID[fieldID] == nil {
            throw CloudModelRuntimeError.unknownField(fieldID)
        }
        for (fieldID, value) in snapshot.fields {
            guard let field = fieldsByID[fieldID] else { continue }
            if case .asset = value {
                // Keep the remote-safe reference until the caller explicitly
                // materializes bytes and supplies an upload lease.
                backing.boundaryValues[field.recordName.rawValue] = value
                backing.record[field.recordName.rawValue] = nil
            } else {
                backing.boundaryValues.removeValue(forKey: field.recordName.rawValue)
                backing.record[field.recordName.rawValue] = try value.cloudKitValue(
                    fieldID: field.id
                )
            }
        }
        if snapshot.isPartial == false {
            for field in modelSchema.fields where snapshot.fields[field.id] == nil {
                backing.boundaryValues.removeValue(forKey: field.recordName.rawValue)
                backing.record[field.recordName.rawValue] = nil
            }
        }
    }

    static func makeCloudModel(
        from snapshot: CloudRecordSnapshot,
        in zone: CloudZoneIdentifier
    ) throws -> Self {
        let expected = try cloudModelIdentifier()
        guard snapshot.modelID == expected else {
            throw CloudModelRuntimeError.modelIdentifierMismatch(
                expected: expected,
                actual: snapshot.modelID
            )
        }
        let ckRecordID = try snapshot.id.cloudKitRecordID(in: zone)
        let backing = CKBackingData<Self>(for: Self.self)
        backing.record = CKRecord(recordType: cloudRecordType, recordID: ckRecordID)
        let model = Self(backingData: backing)
        try model.applyCloudRecordSnapshot(snapshot)
        return model
    }
}
