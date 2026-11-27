import CloudKit

/// The record behind a legacy backing object, independent of its model type.
///
/// `relatedBackingData` stores backing objects of many model types as `Any`.
/// A cast to a parameterized existential such as
/// `any BackingData<any CloudKitModel>` never matches a concrete
/// `CKBackingData<Model>`, so related records are reached through this
/// protocol instead.
protocol CKRecordBacking: AnyObject {
    var record: CKRecord { get set }
}

extension CKBackingData: CKRecordBacking {}

extension CKBackingData {
    /// Every record this model relates to, through to-one and to-many
    /// relationships, whether it was assigned in memory or preloaded as a raw
    /// record. Each record appears once, ordered by relationship name and
    /// record name so a save is deterministic.
    var relatedRecordsToSave: [CKRecord] {
        var records = [CKRecord]()
        var seen: Set<CKRecord.ID> = [recordID]
        for name in relatedBackingData.keys.sorted() {
            for record in Self.relatedRecords(in: relatedBackingData[name])
                where seen.insert(record.recordID).inserted
            {
                records.append(record)
            }
        }
        return records
    }

    /// Replaces each related record with the copy the server returned, so the
    /// next save sends the current change tags.
    func adoptSavedRelatedRecords(_ saved: [CKRecord.ID: CKRecord]) {
        for name in Array(relatedBackingData.keys) {
            relatedBackingData[name] = Self.adopting(saved, in: relatedBackingData[name])
        }
    }

    /// The related model stored for a relationship, whether it was assigned
    /// in memory or preloaded as a raw record. A preloaded record is wrapped
    /// without copying, so edits made through the model reach the stored
    /// record.
    func storedRelatedModel<Related: CloudKitModel>(
        _ value: Any?,
        as modelType: Related.Type
    ) -> Related? {
        if let backing = value as? CKBackingData<Related> {
            return Related(backingData: backing)
        }
        if let record = value as? CKRecord {
            let backing = CKBackingData<Related>(for: Related.self, database: database)
            backing.record = record
            return Related(backingData: backing)
        }
        return nil
    }

    private static func relatedRecords(in value: Any?) -> [CKRecord] {
        if let backing = value as? CKRecordBacking {
            return [backing.record]
        }
        if let record = value as? CKRecord {
            return [record]
        }
        if let collection = value as? [String: Any] {
            return collection.keys.sorted().flatMap { relatedRecords(in: collection[$0]) }
        }
        return []
    }

    private static func adopting(_ saved: [CKRecord.ID: CKRecord], in value: Any?) -> Any? {
        if let backing = value as? CKRecordBacking {
            if let savedRecord = saved[backing.record.recordID] {
                backing.record = savedRecord
            }
            return value
        }
        if let record = value as? CKRecord {
            return saved[record.recordID] ?? record
        }
        if let collection = value as? [String: Any] {
            return collection.compactMapValues { adopting(saved, in: $0) }
        }
        return value
    }
}
