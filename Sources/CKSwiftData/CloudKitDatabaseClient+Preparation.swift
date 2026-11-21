import CloudKit

struct CloudKitPreflightConflict: Error {
    let id: CloudRecordIdentifier
    let expectedChangeTag: String
    let actualChangeTag: String?
    let server: CloudRecordSnapshot
}

extension CloudKitDatabaseClient {
    func model(for id: CloudModelIdentifier) throws -> CloudModelSchema {
        guard let model = schema.model(id) else {
            throw CloudContextError.unknownModel(id)
        }
        return model
    }

    func prepareRecord(
        for mutation: CloudRecordMutation,
        model: CloudModelSchema,
        assets: [CloudAssetMutationKey: CloudAssetUpload]
    ) async throws -> CKRecord {
        try model.validate(mutation: mutation)
        let ckID = try cloudRecordID(from: mutation.id)
        let record: CKRecord
        switch mutation.policy {
        case .insert:
            record = CKRecord(recordType: model.recordType.rawValue, recordID: ckID)
        case let .update(expectedChangeTag):
            let fetched: CKRecord
            do {
                fetched = try await database.record(for: ckID)
            } catch {
                if let cloudError = error as? CKError,
                   cloudError.code == .unknownItem
                {
                    throw CloudModelError.notFound(mutation.id)
                }
                throw map(error: error, id: mutation.id)
            }
            guard fetched.recordChangeTag == expectedChangeTag else {
                throw try CloudKitPreflightConflict(
                    id: mutation.id,
                    expectedChangeTag: expectedChangeTag,
                    actualChangeTag: fetched.recordChangeTag,
                    server: snapshot(from: fetched, model: model)
                )
            }
            record = fetched
        case .upsert:
            do {
                record = try await database.record(for: ckID)
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: model.recordType.rawValue, recordID: ckID)
            } catch {
                throw map(error: error, id: mutation.id)
            }
        }

        let fields = Dictionary(uniqueKeysWithValues: model.fields.map { ($0.id, $0) })
        for (fieldID, value) in mutation.values {
            guard let field = fields[fieldID] else {
                throw CloudModelError.invalidRequest("field \(fieldID.rawValue) is not in the schema")
            }
            let encoded = try ckValue(
                value,
                fieldID: fieldID,
                upload: assets[CloudAssetMutationKey(recordID: mutation.id, fieldID: fieldID)]
            )
            if field.isEncrypted {
                // CloudKit rejects a key that exists in both storage maps with
                // an Objective-C exception. Remove an old value from either
                // map before writing the replacement. The encrypted map must
                // be cleared first when the record already contains an
                // encrypted value; clearing the normal map first would itself
                // trigger the same exception.
                let key = field.recordName.rawValue
                if record.encryptedValues[key] != nil {
                    record.encryptedValues[key] = nil
                }
                if record[key] != nil {
                    record[key] = nil
                }
                record.encryptedValues[key] = encoded
            } else {
                let key = field.recordName.rawValue
                // Also clear a stale encrypted value so a schema transition
                // back to a normal field cannot leave both maps populated.
                if record.encryptedValues[key] != nil {
                    record.encryptedValues[key] = nil
                }
                record[key] = encoded
            }
        }
        for fieldID in mutation.removedFields {
            guard let field = fields[fieldID] else {
                throw CloudModelError.invalidRequest("field \(fieldID.rawValue) is not in the schema")
            }
            let key = field.recordName.rawValue
            if field.isEncrypted {
                if record.encryptedValues[key] != nil {
                    record.encryptedValues[key] = nil
                }
                if record[key] != nil {
                    record[key] = nil
                }
            } else {
                if record.encryptedValues[key] != nil {
                    record.encryptedValues[key] = nil
                }
                record[key] = nil
            }
        }
        return record
    }
}
