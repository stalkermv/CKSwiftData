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
                recordName: value.recordID.recordName,
                zone: zoneOverride ?? .init(value.recordID.zoneID.zoneName)
            ))
        }
        if let value = rawValue as? [String], value.isEmpty == false { return .stringArray(value) }
        if let value = rawValue as? [Int64], value.isEmpty == false { return .int64Array(value) }
        if let value = rawValue as? [Double], value.isEmpty == false { return .doubleArray(value) }
        if let value = rawValue as? [Date], value.isEmpty == false { return .dateArray(value) }
        if let value = rawValue as? [CKRecord.Reference], value.isEmpty == false {
            return try .referenceArray(value.map { reference in
                try CloudRecordIdentifier(
                    recordName: reference.recordID.recordName,
                    zone: zoneOverride ?? .init(reference.recordID.zoneID.zoneName)
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
