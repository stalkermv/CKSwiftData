import CloudKit
import Foundation

public enum CloudKitDatabaseClientError: Error, Codable, Equatable, Hashable, Sendable {
    case invalidZone(CloudZoneIdentifier)
    case unsupportedAsset(CloudFieldIdentifier)
    case unsupportedValue(CloudFieldIdentifier)
    case invalidRemoteRecord(CloudRecordIdentifier, reason: String)
    case unknownCursor(CloudPageCursor)
    case cursorRequestMismatch(CloudPageCursor)
    case cursorInUse(CloudPageCursor)
    case encryptedFieldInPublicDatabase(CloudModelIdentifier, CloudFieldIdentifier)
    case sharedZoneOwnerRequired(CloudZoneIdentifier)
}

/// A production `CloudDatabaseClient` backed by an explicitly injected
/// `CKDatabase`. The adapter never reaches for `CKContainer.default()`.
public actor CloudKitDatabaseClient: CloudDatabaseClient {
    public nonisolated let schema: CloudSchema
    public nonisolated let configuration: CloudStoreConfiguration

    let database: CKDatabase
    let zoneID: CKRecordZone.ID?
    private struct CursorEntry {
        let remoteCursor: CKQueryOperation.Cursor
        let modelID: CloudModelIdentifier
        let desiredFields: Set<CloudFieldIdentifier>
        let createdAt: Date
        var inFlight: Bool
    }

    private var cursors: [String: CursorEntry] = [:]
    private let cursorLimit = 256

    public init(
        schema: CloudSchema,
        configuration: CloudStoreConfiguration,
        database: CKDatabase
    ) throws {
        self.schema = schema
        self.configuration = configuration
        self.database = database
        switch configuration.location {
        case .publicDatabase:
            zoneID = nil
        case .privateDatabase:
            let zone = try configuration.recordZoneIdentifier()
            zoneID = CKRecordZone.ID(
                zoneName: zone.rawValue,
                ownerName: CKCurrentUserDefaultName
            )
        case .sharedDatabase:
            throw try CloudKitDatabaseClientError.sharedZoneOwnerRequired(
                configuration.recordZoneIdentifier()
            )
        }
        if case .publicDatabase = configuration.location {
            for model in schema.models {
                for field in model.fields {
                    if case let .attribute(attribute) = field, attribute.encrypted {
                        throw CloudKitDatabaseClientError.encryptedFieldInPublicDatabase(
                            model.id,
                            field.id
                        )
                    }
                }
            }
        }
    }

    public func fetch(_ request: CloudRecordFetchRequest) async throws -> CloudRecordPage {
        guard let model = schema.model(request.modelID) else {
            throw CloudContextError.unknownModel(request.modelID)
        }
        let desiredKeys = request.desiredFields.isEmpty
            ? nil
            : request.desiredFields.compactMap { model.field($0)?.recordName.rawValue }
        guard request.desiredFields.isEmpty || desiredKeys?.count == request.desiredFields.count else {
            throw CloudModelError.invalidRequest("desired field is not present in the schema")
        }

        let result: (
            matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)],
            queryCursor: CKQueryOperation.Cursor?
        )
        do {
            if let cursor = request.cursor {
                guard var entry = cursors[cursor.rawValue] else {
                    throw CloudKitDatabaseClientError.unknownCursor(cursor)
                }
                guard entry.modelID == request.modelID,
                      entry.desiredFields == request.desiredFields
                else {
                    throw CloudKitDatabaseClientError.cursorRequestMismatch(cursor)
                }
                guard entry.inFlight == false else {
                    throw CloudKitDatabaseClientError.cursorInUse(cursor)
                }
                entry.inFlight = true
                cursors[cursor.rawValue] = entry
                do {
                    result = try await database.records(
                        continuingMatchFrom: entry.remoteCursor,
                        desiredKeys: desiredKeys,
                        resultsLimit: request.limit
                    )
                    // Consume a continuation only after CloudKit accepts the
                    // request. A retryable transport error must be able to
                    // replay the same cursor; removing it before the request
                    // turns that retry into `unknownCursor`.
                    cursors.removeValue(forKey: cursor.rawValue)
                } catch {
                    // A rejected/transport-failed request did not advance the
                    // remote cursor. Release the lease so the caller can retry.
                    if var current = cursors[cursor.rawValue] {
                        current.inFlight = false
                        cursors[cursor.rawValue] = current
                    }
                    throw error
                }
            } else {
                let query = CKQuery(
                    recordType: model.recordType.rawValue,
                    predicate: NSPredicate(value: true)
                )
                result = try await database.records(
                    matching: query,
                    inZoneWith: zoneID,
                    desiredKeys: desiredKeys,
                    resultsLimit: request.limit
                )
            }
        } catch is CancellationError {
            throw CloudModelError.cancelled
        } catch let error as CloudModelError {
            throw error
        } catch let error as CloudKitDatabaseClientError {
            throw error
        } catch {
            throw map(error: error)
        }

        var snapshots = [CloudRecordSnapshot]()
        var failures = [CloudRecordFailure]()
        for (recordID, match) in result.matchResults {
            switch match {
            case let .success(record):
                do {
                    try snapshots.append(snapshot(
                        from: record,
                        model: model,
                        isPartial: request.desiredFields.isEmpty == false
                    ))
                } catch {
                    try failures.append(CloudRecordFailure(
                        id: cloudRecordIdentifier(from: recordID),
                        operation: .fetch,
                        error: error as? CloudModelError ?? .invalidRequest(String(describing: error))
                    ))
                }
            case let .failure(error):
                let id = try cloudRecordIdentifier(from: recordID)
                failures.append(CloudRecordFailure(
                    id: id,
                    operation: .fetch,
                    error: map(error: error, id: id)
                ))
            }
        }
        if let remoteCursor = result.queryCursor {
            let token = UUID().uuidString
            if cursors.count >= cursorLimit,
               let evicted = cursors
               .filter({ $0.value.inFlight == false })
               .min(by: { $0.value.createdAt < $1.value.createdAt })
            {
                cursors.removeValue(forKey: evicted.key)
            }
            cursors[token] = CursorEntry(
                remoteCursor: remoteCursor,
                modelID: request.modelID,
                desiredFields: request.desiredFields,
                createdAt: Date(),
                inFlight: false
            )
            return try CloudRecordPage(
                snapshots: snapshots,
                nextCursor: CloudPageCursor(token),
                failures: failures
            )
        }
        return try CloudRecordPage(snapshots: snapshots, failures: failures)
    }

    public func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        atomic: Bool
    ) async throws -> CloudModifyResult {
        try await modify(
            saving: mutations,
            deleting: recordIDs,
            assets: [:],
            atomic: atomic
        )
    }

    /// Uploads staged local assets together with their record mutations. The
    /// caller owns the leases and may clean them after this operation returns.
    public func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        assets: [CloudAssetMutationKey: CloudAssetUpload],
        atomic: Bool
    ) async throws -> CloudModifyResult {
        guard mutations.isEmpty == false || recordIDs.isEmpty == false else {
            return try CloudModifyResult()
        }
        let configuredZone = try configuration.recordZoneIdentifier()
        for mutation in mutations where mutation.id.zone != configuredZone {
            throw CloudKitDatabaseClientError.invalidZone(mutation.id.zone)
        }
        for id in recordIDs where id.zone != configuredZone {
            throw CloudKitDatabaseClientError.invalidZone(id.zone)
        }
        let effectiveAtomic = atomic && configuration.supportsAtomicWrites
        var records = [CKRecord]()
        var failures = [CloudRecordFailure]()
        var atomicPreflightConflict = false

        for mutation in mutations {
            do {
                let model = try model(for: mutation.modelID)
                let record = try await prepareRecord(
                    for: mutation,
                    model: model,
                    assets: assets
                )
                records.append(record)
            } catch let conflict as CloudKitPreflightConflict {
                let error = CloudModelError.conflict(
                    conflict.id,
                    expectedChangeTag: conflict.expectedChangeTag,
                    actualChangeTag: conflict.actualChangeTag
                )
                if effectiveAtomic { atomicPreflightConflict = true }
                var clientFields = conflict.server.fields
                for fieldID in mutation.removedFields {
                    clientFields.removeValue(forKey: fieldID)
                }
                for (fieldID, value) in mutation.values {
                    clientFields[fieldID] = value
                }
                let client = try? CloudRecordSnapshot(
                    id: mutation.id,
                    modelID: mutation.modelID,
                    changeTag: conflict.expectedChangeTag,
                    fields: clientFields
                )
                failures.append(CloudRecordFailure(
                    id: mutation.id,
                    operation: .save,
                    error: error,
                    conflict: client.map {
                        CloudRecordConflict(
                            id: mutation.id,
                            client: $0,
                            server: conflict.server
                        )
                    }
                ))
            } catch {
                let error = error as? CloudModelError ?? map(error: error, id: mutation.id)
                if effectiveAtomic { throw error }
                failures.append(CloudRecordFailure(
                    id: mutation.id,
                    operation: .save,
                    error: error
                ))
            }
        }

        if effectiveAtomic, atomicPreflightConflict {
            return try CloudModifyResult(failures: failures)
        }

        let deleteIDs = try recordIDs.map(cloudRecordID(from:))
        if records.isEmpty, deleteIDs.isEmpty {
            return try CloudModifyResult(failures: failures)
        }
        let result: (
            saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
            deleteResults: [CKRecord.ID: Result<Void, any Error>]
        )
        do {
            result = try await database.modifyRecords(
                saving: records,
                deleting: deleteIDs,
                savePolicy: .ifServerRecordUnchanged,
                atomically: effectiveAtomic
            )
        } catch is CancellationError {
            throw CloudModelError.cancelled
        } catch {
            throw map(error: error)
        }

        var saved = [CloudRecordSnapshot]()
        for record in records {
            guard let outcome = result.saveResults[record.recordID] else { continue }
            let id = try cloudRecordIdentifier(from: record.recordID)
            switch outcome {
            case let .success(savedRecord):
                guard let mutation = mutations.first(where: { $0.id == id }) else {
                    throw CloudModelError.invalidRequest("missing prepared model")
                }
                let model = try model(for: mutation.modelID)
                try saved.append(snapshot(from: savedRecord, model: model))
            case let .failure(error):
                let mutation = mutations.first { $0.id == id }
                let modelID = mutation?.modelID
                let mapped = map(error: error, id: id)
                failures.append(CloudRecordFailure(
                    id: id,
                    operation: .save,
                    error: mapped,
                    conflict: conflict(
                        from: error,
                        id: id,
                        modelID: modelID,
                        clientRecord: record
                    )
                ))
            }
        }

        var deleted = [CloudRecordIdentifier]()
        for id in recordIDs {
            let ckID = try cloudRecordID(from: id)
            guard let outcome = result.deleteResults[ckID] else { continue }
            switch outcome {
            case .success:
                deleted.append(id)
            case let .failure(error):
                failures.append(CloudRecordFailure(
                    id: id,
                    operation: .delete,
                    error: map(error: error, id: id)
                ))
            }
        }
        let hasConflictFailure = failures.contains { failure in
            if failure.conflict != nil { return true }
            if case .conflict = failure.error { return true }
            return false
        }
        if effectiveAtomic,
           failures.isEmpty == false,
           atomicPreflightConflict == false,
           hasConflictFailure == false
        {
            throw failures[0].error
        }
        return try CloudModifyResult(saved: saved, deleted: deleted, failures: failures)
    }
}
