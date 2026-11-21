import Foundation

extension CKSwiftDataTesting.InMemoryCloudDatabaseClient {
    static func validateBatch(
        mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier]
    ) throws {
        var mutationIDs = Set<CloudRecordIdentifier>()
        for mutation in mutations {
            guard mutationIDs.insert(mutation.id).inserted else {
                throw CloudModelError.invalidRequest(
                    "a modify batch cannot save the same record twice"
                )
            }
        }

        var deletionIDs = Set<CloudRecordIdentifier>()
        for id in recordIDs {
            guard deletionIDs.insert(id).inserted else {
                throw CloudModelError.invalidRequest(
                    "a modify batch cannot delete the same record twice"
                )
            }
            guard mutationIDs.contains(id) == false else {
                throw CloudModelError.invalidRequest(
                    "a modify batch cannot save and delete the same record"
                )
            }
        }
    }

    static func apply(
        _ mutation: CloudRecordMutation,
        to records: inout [CloudRecordIdentifier: CloudRecordSnapshot],
        nextChangeTag: inout Int
    ) -> Result<CloudRecordSnapshot, CloudModelError> {
        guard let current = records[mutation.id] else {
            switch mutation.policy {
            case let .update(expectedChangeTag):
                return .failure(
                    .conflict(
                        mutation.id,
                        expectedChangeTag: expectedChangeTag,
                        actualChangeTag: nil
                    )
                )
            case .insert, .upsert:
                break
            }

            nextChangeTag += 1
            let result: CloudRecordSnapshot
            do {
                result = try Self.updatedSnapshot(
                    id: mutation.id,
                    modelID: mutation.modelID,
                    currentFields: [:],
                    values: mutation.values,
                    removedFields: mutation.removedFields,
                    changeTag: Self.changeTag(for: nextChangeTag)
                )
            } catch {
                return .failure(.invalidRequest("invalid record snapshot: \(error)"))
            }
            records[mutation.id] = result
            return .success(result)
        }

        guard current.modelID == mutation.modelID else {
            return .failure(
                .invalidRequest("record \(mutation.id.recordName) belongs to another model")
            )
        }

        switch mutation.policy {
        case .insert:
            return .failure(
                .conflict(
                    mutation.id,
                    expectedChangeTag: nil,
                    actualChangeTag: current.changeTag
                )
            )
        case let .update(expectedChangeTag):
            guard current.changeTag == expectedChangeTag else {
                return .failure(
                    .conflict(
                        mutation.id,
                        expectedChangeTag: expectedChangeTag,
                        actualChangeTag: current.changeTag
                    )
                )
            }
        case .upsert:
            break
        }

        nextChangeTag += 1
        let result: CloudRecordSnapshot
        do {
            result = try Self.updatedSnapshot(
                id: current.id,
                modelID: current.modelID,
                currentFields: current.fields,
                values: mutation.values,
                removedFields: mutation.removedFields,
                changeTag: Self.changeTag(for: nextChangeTag)
            )
        } catch {
            return .failure(.invalidRequest("invalid record snapshot: \(error)"))
        }
        records[mutation.id] = result
        return .success(result)
    }

    static func applyDelete(
        _ id: CloudRecordIdentifier,
        to records: inout [CloudRecordIdentifier: CloudRecordSnapshot]
    ) -> Result<Void, CloudModelError> {
        guard records.removeValue(forKey: id) != nil else {
            return .failure(.notFound(id))
        }
        return .success(())
    }

    static func updatedSnapshot(
        id: CloudRecordIdentifier,
        modelID: CloudModelIdentifier,
        currentFields: [CloudFieldIdentifier: CloudRecordValue],
        values: [CloudFieldIdentifier: CloudRecordValue],
        removedFields: Set<CloudFieldIdentifier>,
        changeTag: String
    ) throws -> CloudRecordSnapshot {
        var fields = currentFields
        for field in removedFields {
            fields.removeValue(forKey: field)
        }
        for (field, value) in values {
            fields[field] = value
        }
        return try CloudRecordSnapshot(
            id: id,
            modelID: modelID,
            changeTag: changeTag,
            fields: fields
        )
    }

    static func conflict(
        for mutation: CloudRecordMutation,
        error: CloudModelError,
        records: [CloudRecordIdentifier: CloudRecordSnapshot]
    ) -> CloudRecordConflict? {
        guard case .conflict = error,
              let server = records[mutation.id] else { return nil }
        let clientChangeTag: String? = switch mutation.policy {
        case let .update(tag): tag
        case .insert, .upsert: nil
        }
        guard let client = try? CloudRecordSnapshot(
            id: mutation.id,
            modelID: mutation.modelID,
            changeTag: clientChangeTag,
            fields: mutation.values
        ) else { return nil }
        return CloudRecordConflict(
            id: mutation.id,
            client: client,
            server: server
        )
    }

    static func project(
        _ snapshot: CloudRecordSnapshot,
        desiredFields: Set<CloudFieldIdentifier>
    ) throws -> CloudRecordSnapshot {
        guard desiredFields.isEmpty == false else { return snapshot }
        let fields = snapshot.fields.filter { desiredFields.contains($0.key) }
        return try CloudRecordSnapshot(
            id: snapshot.id,
            modelID: snapshot.modelID,
            changeTag: snapshot.changeTag,
            fields: fields,
            isPartial: true
        )
    }

    static func startIndex(
        for cursor: CloudPageCursor?,
        count: Int
    ) throws -> Int {
        guard let cursor else { return 0 }
        let prefix = "offset:"
        guard cursor.rawValue.hasPrefix(prefix),
              let offset = Int(cursor.rawValue.dropFirst(prefix.count)),
              offset >= 0,
              offset <= count
        else {
            throw CloudModelError.invalidRequest("invalid in-memory page cursor")
        }
        return offset
    }

    static func recordOrder(
        _ lhs: CloudRecordSnapshot,
        _ rhs: CloudRecordSnapshot
    ) -> Bool {
        if lhs.modelID != rhs.modelID {
            return lhs.modelID < rhs.modelID
        }
        return lhs.id < rhs.id
    }

    static func changeTag(for counter: Int) -> String { "c\(counter)" }

    static func counterValue(in changeTag: String) -> Int {
        guard changeTag.first == "c",
              let value = Int(changeTag.dropFirst()),
              value > 0
        else {
            return 0
        }
        return value
    }
}
