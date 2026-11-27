import Foundation

/// Namespace for deterministic clients and failure drivers used by tests.
public enum CKSwiftDataTesting {}

extension CKSwiftDataTesting {
    /// An actor-isolated, deterministic implementation of `CloudDatabaseClient`.
    ///
    /// Records are ordered by model, zone, and record name. Cursors encode that
    /// implementation's offset and are intentionally opaque to callers. The fake
    /// applies the same optimistic write policies as the production boundary and
    /// never mutates state after a failed atomic batch.
    public actor InMemoryCloudDatabaseClient: CloudDatabaseClient {
        private var records: [CloudRecordIdentifier: CloudRecordSnapshot]
        private var nextChangeTag: Int
        private var orderedRecordIDsByModel: [CloudModelIdentifier: [CloudRecordIdentifier]]?

        public init(initial: [CloudRecordSnapshot] = []) throws {
            var materialized = [CloudRecordIdentifier: CloudRecordSnapshot](
                minimumCapacity: initial.count
            )
            var seen = Set<CloudRecordIdentifier>()
            var counter = 0

            for snapshot in initial {
                guard seen.insert(snapshot.id).inserted else {
                    throw CloudRecordBoundaryError.duplicateRecordIdentifier(snapshot.id)
                }

                let materializedSnapshot: CloudRecordSnapshot
                if let changeTag = snapshot.changeTag {
                    materializedSnapshot = snapshot
                    counter = max(counter, Self.counterValue(in: changeTag))
                } else {
                    counter += 1
                    materializedSnapshot = try CloudRecordSnapshot(
                        id: snapshot.id,
                        modelID: snapshot.modelID,
                        changeTag: Self.changeTag(for: counter),
                        fields: snapshot.fields
                    )
                }
                materialized[snapshot.id] = materializedSnapshot
            }

            records = materialized
            nextChangeTag = counter
            orderedRecordIDsByModel = nil
        }

        public func fetch(_ request: CloudRecordFetchRequest) async throws -> CloudRecordPage {
            if orderedRecordIDsByModel == nil {
                orderedRecordIDsByModel = Self.buildOrderedRecordIDsByModel(records)
            }
            let matchingIDs = orderedRecordIDsByModel?[request.modelID] ?? []

            let startIndex = try Self.startIndex(for: request.cursor, count: matchingIDs.count)
            let endIndex = startIndex + min(request.limit, matchingIDs.count - startIndex)
            let page: [CloudRecordSnapshot]
            do {
                page = try matchingIDs[startIndex ..< endIndex].map { id in
                    guard let snapshot = records[id] else {
                        throw CloudModelError.invalidRequest(
                            "the in-memory order index referenced a missing record"
                        )
                    }
                    return try Self.project(snapshot, desiredFields: request.desiredFields)
                }
            } catch {
                throw CloudModelError.invalidRequest(
                    "the in-memory client could not project the requested fields"
                )
            }
            let nextCursor: CloudPageCursor? = if endIndex < matchingIDs.count {
                try CloudPageCursor("offset:\(endIndex)")
            } else {
                nil
            }
            return try CloudRecordPage(snapshots: page, nextCursor: nextCursor)
        }

        public func modify(
            saving mutations: [CloudRecordMutation],
            deleting recordIDs: [CloudRecordIdentifier],
            atomic: Bool
        ) async throws -> CloudModifyResult {
            try Self.validateBatch(mutations: mutations, deleting: recordIDs)

            if atomic {
                var working = records
                var counter = nextChangeTag
                var saved = [CloudRecordSnapshot]()
                var deleted = [CloudRecordIdentifier]()

                for mutation in mutations {
                    let outcome = Self.apply(
                        mutation,
                        to: &working,
                        nextChangeTag: &counter
                    )
                    switch outcome {
                    case let .success(snapshot):
                        saved.append(snapshot)
                    case let .failure(error):
                        throw error
                    }
                }

                for id in recordIDs {
                    switch Self.applyDelete(id, to: &working) {
                    case .success:
                        deleted.append(id)
                    case let .failure(error):
                        throw error
                    }
                }

                records = working
                nextChangeTag = counter
                orderedRecordIDsByModel = nil
                return try CloudModifyResult(saved: saved, deleted: deleted)
            }

            var saved = [CloudRecordSnapshot]()
            var deleted = [CloudRecordIdentifier]()
            var failures = [CloudRecordFailure]()

            for mutation in mutations {
                switch Self.apply(
                    mutation,
                    to: &records,
                    nextChangeTag: &nextChangeTag
                ) {
                case let .success(snapshot):
                    saved.append(snapshot)
                case let .failure(error):
                    failures.append(
                        CloudRecordFailure(
                            id: mutation.id,
                            operation: .save,
                            error: error,
                            conflict: Self.conflict(
                                for: mutation,
                                error: error,
                                records: records
                            )
                        )
                    )
                }
            }

            for id in recordIDs {
                switch Self.applyDelete(id, to: &records) {
                case .success:
                    deleted.append(id)
                case let .failure(error):
                    failures.append(CloudRecordFailure(id: id, operation: .delete, error: error))
                }
            }

            orderedRecordIDsByModel = nil
            return try CloudModifyResult(saved: saved, deleted: deleted, failures: failures)
        }

        private static func buildOrderedRecordIDsByModel(
            _ records: [CloudRecordIdentifier: CloudRecordSnapshot]
        ) -> [CloudModelIdentifier: [CloudRecordIdentifier]] {
            var ordered = [CloudModelIdentifier: [CloudRecordIdentifier]]()
            for snapshot in records.values.sorted(by: Self.recordOrder) {
                ordered[snapshot.modelID, default: []].append(snapshot.id)
            }
            return ordered
        }
    }
}
