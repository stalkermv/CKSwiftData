import Foundation

/// The lifecycle of a record tracked by a local context.
public enum CloudModelState: String, Codable, Hashable, Sendable {
    case detached
    case inserted
    case clean
    case dirty
    case deleted
}

/// Errors raised before a record operation reaches the database client.
public enum CloudContextError: Error, Codable, Equatable, Hashable, Sendable {
    case unknownModel(CloudModelIdentifier)
    case invalidZone(expected: CloudZoneIdentifier, actual: CloudZoneIdentifier)
    case recordBelongsToAnotherModel(
        CloudRecordIdentifier,
        expected: CloudModelIdentifier,
        actual: CloudModelIdentifier
    )
    case recordAlreadyTracked(CloudRecordIdentifier)
    case cannotModifyDeletedRecord(CloudRecordIdentifier)
    case cannotDiscardUntrackedRecord(CloudRecordIdentifier)
    case missingConflictServerSnapshot(CloudRecordIdentifier)
    case partialSnapshotRequiresFullFetch(CloudRecordIdentifier)
    case partialRefreshRequiresFullFetch(CloudModelIdentifier)
}

/// Explicit relationship loading state. An unloaded relationship is not
/// represented by an empty collection or a nil value.
public enum CloudRelationshipState<Value> {
    case unloaded
    case loaded(Value)
    case failed(CloudModelError)

    public var value: Value? {
        guard case let .loaded(value) = self else { return nil }
        return value
    }

    public var error: CloudModelError? {
        guard case let .failed(error) = self else { return nil }
        return error
    }
}

/// A main-actor identity map and change tracker for immutable record values.
///
/// The context never performs implicit network I/O from a property getter. A
/// fetch, save, refresh, or rollback is an explicit asynchronous operation.
@MainActor
public final class CloudRecordContext {
    public let schema: CloudSchema
    public let store: CloudKitRecordStore

    var snapshots: [CloudRecordIdentifier: CloudRecordSnapshot] = [:]
    var baselines: [CloudRecordIdentifier: CloudRecordSnapshot] = [:]
    var states: [CloudRecordIdentifier: CloudModelState] = [:]
    var stagedMutations: [CloudRecordIdentifier: CloudRecordMutation] = [:]
    var stagedDeletes: Set<CloudRecordIdentifier> = []
    var revisions: [CloudRecordIdentifier: UInt64] = [:]
    var nextRevision: UInt64 = 0
    var nextFetchGeneration: UInt64 = 0
    var latestFetchGenerations: [CloudRecordIdentifier: UInt64] = [:]
    var latestDiscardFetchGenerations: [CloudRecordIdentifier: UInt64] = [:]
    var discardBarrierEpochs: [CloudRecordIdentifier: UInt64] = [:]
    var discardRefreshEpochs: [CloudModelIdentifier: UInt64] = [:]
    var activeDiscardRefreshes: [CloudModelIdentifier: Int] = [:]
    var nextSaveGeneration: UInt64 = 0
    var latestSaveGenerations: [CloudRecordIdentifier: UInt64] = [:]
    var latestCommittedSaveGenerations: [CloudRecordIdentifier: UInt64] = [:]
    var failures: [CloudRecordIdentifier: CloudModelError] = [:]
    var conflicts: [CloudRecordIdentifier: CloudRecordConflict] = [:]

    public init(store: CloudKitRecordStore) {
        self.store = store
        schema = store.schema
    }

    public convenience init(
        schema: CloudSchema,
        configuration: CloudStoreConfiguration,
        client: any CloudDatabaseClient
    ) {
        let store = CloudKitRecordStore(
            schema: schema,
            configuration: configuration,
            client: client
        )
        self.init(store: store)
    }

    /// Fetches one page and merges only records without local changes.
    public func fetch(
        _ request: CloudRecordFetchRequest,
        retryPolicy: CloudRetryPolicy = .none
    ) async throws -> CloudRecordPage {
        let fetchGeneration = beginFetchGeneration()
        let discardEpochAtStart = discardRefreshEpochs[request.modelID] ?? 0
        let discardWasInFlightAtStart = (activeDiscardRefreshes[request.modelID] ?? 0) > 0
        let startingRevisions = revisions
        let startingStates = states
        let page = try await store.fetch(request, retryPolicy: retryPolicy)
        for snapshot in page.snapshots {
            guard shouldSkipOrdinaryFetch(
                for: snapshot.id,
                discardEpochAtStart: discardEpochAtStart,
                discardWasInFlightAtStart: discardWasInFlightAtStart
            ) == false else { continue }
            let revisionAtStart = startingRevisions[snapshot.id] ?? 0
            let revisionNow = revisions[snapshot.id] ?? 0
            let stateAtStart = startingStates[snapshot.id] ?? .detached
            let stateNow = states[snapshot.id] ?? .detached
            guard revisionAtStart == revisionNow, stateAtStart == stateNow else {
                // A local transition completed while the request was in
                // flight. The page is stale for this identity; keep the
                // newer local snapshot and let the typed layer preserve any
                // direct setter that is still visible on the bound model.
                continue
            }
            let previousFetchGeneration = latestFetchGenerations[snapshot.id]
            guard acceptFetchGeneration(for: snapshot.id, generation: fetchGeneration) else {
                continue
            }
            if mergeFetched(snapshot) == false {
                if let previousFetchGeneration {
                    latestFetchGenerations[snapshot.id] = previousFetchGeneration
                } else {
                    latestFetchGenerations.removeValue(forKey: snapshot.id)
                }
            }
        }
        mergeFetchFailures(
            page.failures.filter {
                shouldSkipOrdinaryFetch(
                    for: $0.id,
                    discardEpochAtStart: discardEpochAtStart,
                    discardWasInFlightAtStart: discardWasInFlightAtStart
                ) == false
            },
            generation: fetchGeneration,
            startingRevisions: startingRevisions,
            startingStates: startingStates
        )
        return page
    }

    /// Re-fetches a page. When `discardLocalChanges` is true, local staged
    /// changes for the returned records are rolled back before merging.
    public func refresh(
        _ request: CloudRecordFetchRequest,
        discardLocalChanges: Bool = false,
        retryPolicy: CloudRetryPolicy = .none
    ) async throws -> CloudRecordPage {
        guard discardLocalChanges else {
            return try await fetch(request, retryPolicy: retryPolicy)
        }
        guard request.desiredFields.isEmpty else {
            throw CloudContextError.partialRefreshRequiresFullFetch(request.modelID)
        }
        let fetchGeneration = beginFetchGeneration()
        let discardEpochAtStart = discardRefreshEpochs[request.modelID] ?? 0
        let startingMutations = stagedMutations
        let startingDeletes = stagedDeletes
        let startingCommittedSaveGenerations = latestCommittedSaveGenerations
        let discardEpochForRequest = discardEpochAtStart &+ 1
        discardRefreshEpochs[request.modelID] = discardEpochForRequest
        activeDiscardRefreshes[request.modelID, default: 0] += 1
        defer {
            let remaining = (activeDiscardRefreshes[request.modelID] ?? 1) - 1
            if remaining > 0 {
                activeDiscardRefreshes[request.modelID] = remaining
            } else {
                activeDiscardRefreshes.removeValue(forKey: request.modelID)
            }
        }
        let startingStates = states
        let page = try await store.fetch(request, retryPolicy: retryPolicy)
        for snapshot in page.snapshots {
            if startingStates[snapshot.id] != nil,
               states[snapshot.id] == nil,
               revisions[snapshot.id] == nil
            {
                // An explicit detach completed while the discard request
                // was in flight. Do not let the older response resurrect
                // the identity-map entry.
                continue
            }
            guard latestCommittedSaveGenerations[snapshot.id] ==
                startingCommittedSaveGenerations[snapshot.id]
            else {
                // A newer successful save already established a server
                // baseline; this discard response was captured too early
                // and must not roll that state back.
                continue
            }
            guard acceptDiscardFetchGeneration(
                for: snapshot.id,
                generation: fetchGeneration
            ) else { continue }
            try mergeDiscardedFetched(
                snapshot,
                startingMutation: startingMutations[snapshot.id],
                hadStartingDelete: startingDeletes.contains(snapshot.id)
            )
            discardBarrierEpochs[snapshot.id] = discardEpochForRequest
        }
        return page
    }

    /// Stages a partial mutation in the identity map. Repeated mutations for a
    /// record are merged deterministically and never sent until `save`.
    public func stage(_ mutation: CloudRecordMutation) throws {
        guard schema.model(mutation.modelID) != nil else {
            throw CloudContextError.unknownModel(mutation.modelID)
        }
        guard states[mutation.id] != .deleted else {
            throw CloudContextError.cannotModifyDeletedRecord(mutation.id)
        }

        let current = snapshots[mutation.id]
        if let current, current.modelID != mutation.modelID {
            throw CloudContextError.recordBelongsToAnotherModel(
                mutation.id,
                expected: mutation.modelID,
                actual: current.modelID
            )
        }

        let mergedMutation = try merge(mutation, with: stagedMutations[mutation.id])
        stagedMutations[mutation.id] = mergedMutation

        var fields = current?.fields ?? [:]
        for field in mutation.removedFields {
            fields.removeValue(forKey: field)
        }
        for (field, value) in mutation.values {
            fields[field] = value
        }
        snapshots[mutation.id] = try CloudRecordSnapshot(
            id: mutation.id,
            modelID: mutation.modelID,
            changeTag: current?.changeTag,
            fields: fields,
            isPartial: current?.isPartial ?? false
        )
        stagedDeletes.remove(mutation.id)
        states[mutation.id] = current == nil ? .inserted : .dirty
        failures.removeValue(forKey: mutation.id)
        conflicts.removeValue(forKey: mutation.id)
        bumpRevision(for: mutation.id)
    }

    /// Tracks a complete local snapshot as an inserted record.
    public func insert(_ snapshot: CloudRecordSnapshot) throws {
        guard schema.model(snapshot.modelID) != nil else {
            throw CloudContextError.unknownModel(snapshot.modelID)
        }
        guard snapshots[snapshot.id] == nil else {
            throw CloudContextError.recordAlreadyTracked(snapshot.id)
        }
        let mutation = try CloudRecordMutation(
            id: snapshot.id,
            modelID: snapshot.modelID,
            values: snapshot.fields,
            policy: .insert
        )
        try stage(mutation)
    }

    /// Marks a tracked record for deletion. The deletion is sent by `save`.
    /// A record that was inserted but never saved does not exist remotely, so
    /// it is discarded locally and no remote delete is staged.
    public func delete(_ id: CloudRecordIdentifier) throws {
        guard snapshots[id] != nil || (states[id] != nil && states[id] != .detached) else {
            throw CloudContextError.cannotDiscardUntrackedRecord(id)
        }
        if states[id] == .inserted, baselines[id] == nil {
            discardChanges(for: id)
            return
        }
        stagedMutations.removeValue(forKey: id)
        stagedDeletes.insert(id)
        states[id] = .deleted
        failures.removeValue(forKey: id)
        conflicts.removeValue(forKey: id)
        bumpRevision(for: id)
    }

    /// Persists all staged mutations and deletions. Partial outcomes are
    /// returned explicitly; records with failures remain dirty for retry.
    public func save(
        atomic: Bool = true,
        retryPolicy: CloudRetryPolicy = .none
    ) async throws -> CloudModifyResult {
        try await save(
            assets: [:],
            atomic: atomic,
            retryPolicy: retryPolicy
        )
    }

    /// Persists staged mutations together with explicitly staged CloudKit
    /// assets. The caller owns the leases and decides when to clean them up.
    public func save(
        assets: [CloudAssetMutationKey: CloudAssetUpload],
        atomic: Bool = true,
        retryPolicy: CloudRetryPolicy = .none
    ) async throws -> CloudModifyResult {
        let mutations = stagedMutations.values.sorted { lhs, rhs in
            if lhs.modelID != rhs.modelID {
                return lhs.modelID < rhs.modelID
            }
            return lhs.id < rhs.id
        }
        let deleting = stagedDeletes.sorted()
        let affectedIDs = mutations.map(\.id) + deleting
        let capturedRevisions = Dictionary(uniqueKeysWithValues: affectedIDs.map {
            ($0, revisions[$0] ?? 0)
        })
        let capturedBaselines = [CloudRecordIdentifier: CloudRecordSnapshot](uniqueKeysWithValues: affectedIDs.compactMap {
            guard let baseline = baselines[$0] else { return nil }
            return ($0, baseline)
        })
        let capturedSnapshots = [CloudRecordIdentifier: CloudRecordSnapshot](uniqueKeysWithValues: affectedIDs.compactMap {
            guard let snapshot = snapshots[$0] else { return nil }
            return ($0, snapshot)
        })
        var capturedDiscardEpochs = [CloudRecordIdentifier: UInt64]()
        for mutation in mutations {
            capturedDiscardEpochs[mutation.id] = discardRefreshEpochs[mutation.modelID] ?? 0
        }
        for id in deleting {
            if let modelID = snapshots[id]?.modelID ?? baselines[id]?.modelID {
                capturedDiscardEpochs[id] = discardRefreshEpochs[modelID] ?? 0
            } else {
                capturedDiscardEpochs[id] = 0
            }
        }
        let saveGeneration = beginSaveGeneration()
        let capturedGenerations = Dictionary(uniqueKeysWithValues: affectedIDs.map {
            ($0, saveGeneration)
        })

        let result = try await store.modify(
            saving: mutations,
            deleting: deleting,
            assets: assets,
            atomic: atomic,
            retryPolicy: retryPolicy
        )
        mergeSaveResult(
            result,
            capturedRevisions: capturedRevisions,
            capturedGenerations: capturedGenerations,
            capturedDiscardEpochs: capturedDiscardEpochs,
            capturedBaselines: capturedBaselines,
            capturedSnapshots: capturedSnapshots
        )
        return result
    }

    /// Drops local changes and restores the last fetched baseline. Inserted
    /// records become detached; clean records remain tracked.
    public func discardChanges(for id: CloudRecordIdentifier) {
        guard states[id] != nil || snapshots[id] != nil else { return }
        stagedMutations.removeValue(forKey: id)
        stagedDeletes.remove(id)
        failures.removeValue(forKey: id)
        conflicts.removeValue(forKey: id)
        bumpRevision(for: id)

        guard let baseline = baselines[id] else {
            snapshots.removeValue(forKey: id)
            baselines.removeValue(forKey: id)
            states[id] = .detached
            return
        }
        snapshots[id] = baseline
        states[id] = .clean
    }

    /// Removes a detached identity-map entry. Tracked dirty values require an
    /// explicit `discardChanges` first.
    public func detach(_ id: CloudRecordIdentifier) throws {
        let state = states[id] ?? .detached
        guard state == .detached || state == .clean else {
            throw CloudContextError.cannotDiscardUntrackedRecord(id)
        }
        snapshots.removeValue(forKey: id)
        baselines.removeValue(forKey: id)
        states.removeValue(forKey: id)
        stagedMutations.removeValue(forKey: id)
        stagedDeletes.remove(id)
        revisions.removeValue(forKey: id)
        latestFetchGenerations.removeValue(forKey: id)
        latestDiscardFetchGenerations.removeValue(forKey: id)
        discardBarrierEpochs.removeValue(forKey: id)
        latestSaveGenerations.removeValue(forKey: id)
        latestCommittedSaveGenerations.removeValue(forKey: id)
        failures.removeValue(forKey: id)
        conflicts.removeValue(forKey: id)
    }

    public func snapshot(for id: CloudRecordIdentifier) -> CloudRecordSnapshot? {
        snapshots[id]
    }

    func pendingMutation(for id: CloudRecordIdentifier) -> CloudRecordMutation? {
        stagedMutations[id]
    }

    public func baseline(for id: CloudRecordIdentifier) -> CloudRecordSnapshot? {
        baselines[id]
    }

    public func state(for id: CloudRecordIdentifier) -> CloudModelState {
        states[id] ?? .detached
    }

    public func lastFailure(for id: CloudRecordIdentifier) -> CloudModelError? {
        failures[id]
    }

    public var hasChanges: Bool {
        stagedMutations.isEmpty == false || stagedDeletes.isEmpty == false
    }
}
