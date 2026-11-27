import CloudKit
import Foundation

extension CloudRecordValue {
    init(
        cloudKitValue rawValue: Any,
        fieldID: CloudFieldIdentifier,
        expectedKind: CloudRecordValueKind? = nil,
        zoneOverride: CloudZoneIdentifier? = nil
    ) throws {
        self = try Self.fromCloudKit(
            rawValue,
            fieldID: fieldID,
            expectedKind: expectedKind,
            zoneOverride: zoneOverride
        )
    }

    static func fromCloudKit(
        _ rawValue: Any,
        fieldID: CloudFieldIdentifier,
        expectedKind: CloudRecordValueKind? = nil,
        zoneOverride: CloudZoneIdentifier? = nil
    ) throws -> CloudRecordValue {
        if let value = rawValue as? String { return .string(value) }
        if let number = CloudKitNumberValue.recordValue(from: rawValue) {
            return number
        }
        if let value = rawValue as? Date { return .date(value) }
        if let value = rawValue as? Data { return .data(value) }
        if let value = rawValue as? CKRecord.Reference {
            return try .reference(CloudRecordIdentifier(
                reference: value,
                fieldID: fieldID,
                zoneOverride: zoneOverride
            ))
        }
        if let value = rawValue as? [String], value.isEmpty == false { return .stringArray(value) }
        if let value = rawValue as? [Int64], value.isEmpty == false { return .int64Array(value) }
        if let value = rawValue as? [Double], value.isEmpty == false { return .doubleArray(value) }
        if let value = rawValue as? [Date], value.isEmpty == false { return .dateArray(value) }
        if let value = rawValue as? [CKRecord.Reference], value.isEmpty == false {
            return try .referenceArray(value.map { reference in
                try CloudRecordIdentifier(
                    reference: reference,
                    fieldID: fieldID,
                    zoneOverride: zoneOverride
                )
            })
        }
        if let expectedKind, rawValue is [Any] || rawValue is NSArray {
            switch expectedKind {
            case .stringArray: return .stringArray([])
            case .int64Array: return .int64Array([])
            case .doubleArray: return .doubleArray([])
            case .dateArray: return .dateArray([])
            case .referenceArray: return .referenceArray([])
            default: break
            }
        }
        if let asset = rawValue as? CKAsset {
            guard let fileURL = asset.fileURL else {
                throw CloudModelRuntimeError.unsupportedField(
                    fieldID,
                    reason: "the CloudKit asset has no materialized file URL"
                )
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let byteCount = (attributes?[.size] as? NSNumber).map(\.int64Value)
            return try .asset(CloudAssetReference(
                assetID: fileURL.lastPathComponent,
                byteCount: byteCount
            ))
        }
        throw CloudModelRuntimeError.unsupportedField(
            fieldID,
            reason: "the CloudKit value has no typed boundary representation"
        )
    }

    func cloudKitValue(fieldID: CloudFieldIdentifier) throws -> CKRecordValueProtocol {
        switch self {
        case let .string(value): return value
        case let .int64(value): return value
        case let .double(value): return value
        case let .bool(value): return value
        case let .date(value): return value
        case let .data(value): return value
        case let .reference(value):
            return try CKRecord.Reference(
                recordID: value.cloudKitRecordID(in: value.zone),
                action: .none
            )
        case let .stringArray(value): return value
        case let .int64Array(value): return value
        case let .doubleArray(value): return value
        case let .dateArray(value): return value
        case let .referenceArray(values):
            return try values.map {
                try CKRecord.Reference(
                    recordID: $0.cloudKitRecordID(in: $0.zone),
                    action: .none
                )
            }
        case .asset:
            throw CloudModelRuntimeError.unsupportedField(
                fieldID,
                reason: "asset downloads must be materialized by CloudAssetStager"
            )
        }
    }
}

extension CloudRecordIdentifier {
    /// Reads a CloudKit reference held by a local record.
    ///
    /// A model created locally keeps its record, and the references other
    /// models store to it, in CloudKit's default zone until the store places
    /// it. Only such an unplaced reference takes `zoneOverride`. A reference
    /// that names another zone explicitly points at a different record space,
    /// so substituting the zone would redirect it to an unrelated or missing
    /// record; it is rejected instead.
    init(
        reference: CKRecord.Reference,
        fieldID: CloudFieldIdentifier,
        zoneOverride: CloudZoneIdentifier?
    ) throws {
        let zoneName = reference.recordID.zoneID.zoneName
        let zone: CloudZoneIdentifier
        if let zoneOverride,
           zoneName != zoneOverride.rawValue,
           zoneName != CKRecordZone.ID.defaultZoneName
        {
            throw CloudModelRuntimeError.unsupportedField(
                fieldID,
                reason: "the reference points to zone \(zoneName), outside the configured zone \(zoneOverride.rawValue)"
            )
        } else if let zoneOverride {
            zone = zoneOverride
        } else {
            zone = try CloudZoneIdentifier(zoneName)
        }
        try self.init(recordName: reference.recordID.recordName, zone: zone)
    }

    func cloudKitRecordID(in zone: CloudZoneIdentifier) throws -> CKRecord.ID {
        guard self.zone == zone else {
            throw CloudModelRuntimeError.invalidSnapshot(
                self,
                reason: "record reference crosses the configured zone"
            )
        }
        // `CloudStoreConfiguration` represents the public database with the
        // synthetic `public` zone. Public records are not in a custom zone;
        // constructing a current-user custom-zone ID here would make a local
        // relationship reference point at the wrong record space.
        if zone.rawValue == "public" {
            return CKRecord.ID(recordName: recordName)
        }
        let zoneID = CKRecordZone.ID(zoneName: zone.rawValue, ownerName: CKCurrentUserDefaultName)
        return CKRecord.ID(recordName: recordName, zoneID: zoneID)
    }
}
