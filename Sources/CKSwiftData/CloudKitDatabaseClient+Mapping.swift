import CloudKit
import Foundation

extension CloudKitDatabaseClient {
    func snapshot(
        from record: CKRecord,
        model: CloudModelSchema,
        isPartial: Bool = false
    ) throws -> CloudRecordSnapshot {
        let id = try cloudRecordIdentifier(from: record.recordID)
        var fields = [CloudFieldIdentifier: CloudRecordValue]()
        for field in model.fields {
            let value: Any? = switch field {
            case let .attribute(attribute) where attribute.encrypted:
                record.encryptedValues[field.recordName.rawValue]
                    ?? record[field.recordName.rawValue]
            default:
                record[field.recordName.rawValue]
            }
            guard let value else { continue }
            fields[field.id] = try boundaryValue(
                value,
                fieldID: field.id,
                expectedKind: field.expectedCloudRecordValueKind
            )
        }
        return try CloudRecordSnapshot(
            id: id,
            modelID: model.id,
            changeTag: record.recordChangeTag,
            fields: fields,
            isPartial: isPartial
        )
    }

    func cloudRecordID(from id: CloudRecordIdentifier) throws -> CKRecord.ID {
        guard let zoneID else {
            return CKRecord.ID(recordName: id.recordName)
        }
        return CKRecord.ID(recordName: id.recordName, zoneID: zoneID)
    }

    func cloudRecordIdentifier(from id: CKRecord.ID) throws -> CloudRecordIdentifier {
        if zoneID == nil {
            return try CloudRecordIdentifier(
                recordName: id.recordName,
                zone: configuration.recordZoneIdentifier()
            )
        }
        return try CloudRecordIdentifier(
            recordName: id.recordName,
            zone: CloudZoneIdentifier(id.zoneID.zoneName)
        )
    }

    func ckValue(
        _ value: CloudRecordValue,
        fieldID: CloudFieldIdentifier,
        upload: CloudAssetUpload? = nil
    ) throws -> CKRecordValueProtocol {
        let configuredZone = try configuration.recordZoneIdentifier()
        switch value {
        case let .string(value): return value
        case let .int64(value): return value
        case let .double(value): return value
        case let .bool(value): return value
        case let .date(value): return value
        case let .data(value): return value
        case let .reference(value):
            guard value.zone == configuredZone else {
                throw CloudKitDatabaseClientError.invalidZone(value.zone)
            }
            return try CKRecord.Reference(recordID: cloudRecordID(from: value), action: .none)
        case let .asset(reference):
            guard let upload, upload.reference.assetID == reference.assetID else {
                throw CloudKitDatabaseClientError.unsupportedAsset(fieldID)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: upload.lease.fileURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue == false else {
                throw CloudKitDatabaseClientError.unsupportedAsset(fieldID)
            }
            return CKAsset(fileURL: upload.lease.fileURL)
        case let .stringArray(value): return value
        case let .int64Array(value): return value
        case let .doubleArray(value): return value
        case let .dateArray(value): return value
        case let .referenceArray(values):
            return try values.map {
                guard $0.zone == configuredZone else {
                    throw CloudKitDatabaseClientError.invalidZone($0.zone)
                }
                return try CKRecord.Reference(recordID: cloudRecordID(from: $0), action: .none)
            }
        }
    }

    func boundaryValue(
        _ value: Any,
        fieldID: CloudFieldIdentifier,
        expectedKind: CloudRecordValueKind? = nil
    ) throws -> CloudRecordValue {
        if let value = value as? String { return .string(value) }
        if let number = CloudKitNumberValue.recordValue(from: value) {
            return number
        }
        if let value = value as? Date { return .date(value) }
        if let value = value as? Data { return .data(value) }
        if let value = value as? CKRecord.Reference {
            return try .reference(cloudRecordIdentifier(from: value.recordID))
        }
        if let values = value as? [String], values.isEmpty == false { return .stringArray(values) }
        if let values = value as? [Int64], values.isEmpty == false { return .int64Array(values) }
        if let values = value as? [Double], values.isEmpty == false { return .doubleArray(values) }
        if let values = value as? [Date], values.isEmpty == false { return .dateArray(values) }
        if let values = value as? [CKRecord.Reference], values.isEmpty == false {
            return try .referenceArray(values.map { try cloudRecordIdentifier(from: $0.recordID) })
        }
        if let expectedKind, value is [Any] || value is NSArray {
            switch expectedKind {
            case .stringArray: return .stringArray([])
            case .int64Array: return .int64Array([])
            case .doubleArray: return .doubleArray([])
            case .dateArray: return .dateArray([])
            case .referenceArray: return .referenceArray([])
            default: break
            }
        }
        if let asset = value as? CKAsset, let fileURL = asset.fileURL {
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            return try .asset(CloudAssetReference(
                assetID: fileURL.lastPathComponent,
                byteCount: (attributes?[.size] as? NSNumber).map(\.int64Value)
            ))
        }
        throw CloudKitDatabaseClientError.unsupportedValue(fieldID)
    }

    func map(error: Error, id: CloudRecordIdentifier? = nil) -> CloudModelError {
        if let error = error as? CloudModelError { return error }
        guard let cloudError = error as? CKError else {
            return .unsupported(String(describing: error))
        }
        let retryAfter = cloudError.retryAfterSeconds
        switch cloudError.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable,
             .requestRateLimited, .zoneBusy:
            return .retryable(cloudError.localizedDescription, retryAfter: retryAfter)
        case .serverRecordChanged:
            guard let id else { return .unsupported(cloudError.localizedDescription) }
            return .conflict(
                id,
                expectedChangeTag: nil,
                actualChangeTag: (cloudError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord)?.recordChangeTag
            )
        case .unknownItem:
            if let id { return .notFound(id) }
            return .unsupported(cloudError.localizedDescription)
        case .notAuthenticated, .permissionFailure, .quotaExceeded:
            return .unsupported(cloudError.localizedDescription)
        default:
            return .unsupported(cloudError.localizedDescription)
        }
    }

    func conflict(
        from error: Error,
        id: CloudRecordIdentifier,
        modelID: CloudModelIdentifier?,
        clientRecord: CKRecord? = nil
    ) -> CloudRecordConflict? {
        guard let modelID,
              let cloudError = error as? CKError,
              let server = cloudError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
              let model = try? model(for: modelID),
              let serverSnapshot = try? snapshot(from: server, model: model)
        else {
            return nil
        }
        let client = (clientRecord.flatMap { try? snapshot(from: $0, model: model) })
            ?? (try? CloudRecordSnapshot(
                id: id,
                modelID: modelID,
                fields: [:]
            ))
            ?? serverSnapshot
        return CloudRecordConflict(id: id, client: client, server: serverSnapshot)
    }
}
