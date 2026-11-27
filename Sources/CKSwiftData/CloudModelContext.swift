import Foundation

/// A typed fetch request for one model declaration.
public struct CloudFetchDescriptor<Model: CloudPersistentModel>: Sendable {
    public let request: CloudRecordFetchRequest

    public init(
        limit: Int = 100,
        cursor: CloudPageCursor? = nil,
        desiredFields: Set<CloudFieldIdentifier> = []
    ) throws {
        let modelID = try Model.cloudModelIdentifier()
        request = try CloudRecordFetchRequest(
            modelID: modelID,
            limit: limit,
            cursor: cursor,
            desiredFields: desiredFields
        )
    }
}

/// A page of materialized models and an explicit continuation cursor.
public struct CloudModelPage<Model: CloudPersistentModel> {
    public let models: [Model]
    public let nextCursor: CloudPageCursor?
    public let failures: [CloudRecordFailure]

    public init(
        models: [Model],
        nextCursor: CloudPageCursor?,
        failures: [CloudRecordFailure] = []
    ) {
        self.models = models
        self.nextCursor = nextCursor
        self.failures = failures
    }
}

/// The typed main-actor facade over `CloudRecordContext`.
@MainActor
public final class CloudModelContext {
    public let recordContext: CloudRecordContext
    public let zone: CloudZoneIdentifier

    private var models: [CloudRecordIdentifier: any CloudPersistentModel] = [:]
    private var rollbackGenerations: [CloudRecordIdentifier: UInt64] = [:]
    private var nextRollbackGeneration: UInt64 = 0
    private var rollbackRestoredFields: [CloudRecordIdentifier: [CloudFieldIdentifier: CloudRecordValue]] = [:]
    private var activeSaveCount = 0

    private struct CapturedModelEdit {
        let id: CloudRecordIdentifier
        let modelID: CloudModelIdentifier
        let values: [CloudFieldIdentifier: CloudRecordValue]
        let removedFields: Set<CloudFieldIdentifier>
    }

    private struct FetchStartCapture {
        let fields: [CloudRecordIdentifier: [CloudFieldIdentifier: CloudRecordValue]]
        let edits: [CapturedModelEdit]
    }

    public init(recordContext: CloudRecordContext, zone: CloudZoneIdentifier) {
        self.recordContext = recordContext
        self.zone = zone
    }

    public func insert<Model: CloudPersistentModel>(_ model: Model) throws {
        let id = try model.cloudRecordIdentifier(in: zone)
        let snapshot = try model.cloudRecordSnapshot(in: zone)
        guard snapshot.id == id else {
            throw CloudModelRuntimeError.invalidSnapshot(
                id,
                reason: "the model returned a different record identifier"
            )
        }
        try recordContext.insert(snapshot)
        models[id] = model
    }

    public func delete<Model: CloudPersistentModel>(_ model: Model) throws {
        let id = try model.cloudRecordIdentifier(in: zone)
        try recordContext.delete(id)
        if recordContext.state(for: id) == .detached {
            models.removeValue(forKey: id)
        }
    }

    public func fetch<Model: CloudPersistentModel>(
        _ descriptor: CloudFetchDescriptor<Model>,
        retryPolicy: CloudRetryPolicy = .none
    ) async throws -> CloudModelPage<Model> {
        let startCapture = try captureFetchStartState()
        let page = try await recordContext.fetch(
            descriptor.request,
            retryPolicy: retryPolicy
        )
        let editsMadeInFlight = try captureDirectModelEditsMadeSince(
            startCapture.fields,
            includingDirtyModels: true
        )
        let capturedEdits = reconcileCapturedEdits(
            mergeCapturedEdits(startCapture.edits, with: editsMadeInFlight),
            against: page.snapshots
        )
        let models = try materialize(
            page.snapshots,
            as: Model.self,
            preservingLocalIDs: Set(capturedEdits.map(\.id))
        )
        try reapplyCapturedEdits(capturedEdits, onto: page.snapshots)
        try rebaseCapturedEdits(capturedEdits, onto: page.snapshots)
        return CloudModelPage(
            models: models,
            nextCursor: page.nextCursor,
            failures: page.failures
        )
    }

    public func refresh<Model: CloudPersistentModel>(
        _ descriptor: CloudFetchDescriptor<Model>,
        discardLocalChanges: Bool = false,
        retryPolicy: CloudRetryPolicy = .none
    ) async throws -> CloudModelPage<Model> {
        if discardLocalChanges,
           descriptor.request.desiredFields.isEmpty == false
        {
            throw CloudContextError.partialRefreshRequiresFullFetch(
                descriptor.request.modelID
            )
        }
        let startingModelFields = try captureModelFieldsForFetch()
        let editsAtStart = discardLocalChanges
            ? []
            : try captureDirectModelEditsRelativeToCurrentSnapshots()
        let inFlightModelFields: [CloudRecordIdentifier: [CloudFieldIdentifier: CloudRecordValue]] =
            discardLocalChanges ? try captureModelFields() : [:]
        let page = try await recordContext.refresh(
            descriptor.request,
            discardLocalChanges: discardLocalChanges,
            retryPolicy: retryPolicy
        )
        let edits = try reconcileCapturedEdits(
            discardLocalChanges
                ? captureDirectModelEditsMadeSince(
                    inFlightModelFields,
                    includingDirtyModels: true
                )
                : mergeCapturedEdits(
                    editsAtStart,
                    with: captureDirectModelEditsMadeSince(
                        startingModelFields,
                        includingDirtyModels: true
                    )
                ),
            against: page.snapshots
        )
        let models = try materialize(
            page.snapshots,
            as: Model.self,
            preservingLocalIDs: Set(edits.map(\.id))
        )
        try reapplyCapturedEdits(edits, onto: page.snapshots)
        try rebaseCapturedEdits(edits, onto: page.snapshots)
        return CloudModelPage(
            models: models,
            nextCursor: page.nextCursor,
            failures: page.failures
        )
    }

    /// Encodes bound model values, stages their field diffs, and persists all
    /// changes. Partial failures remain visible through the returned result and
    /// through `recordContext.lastFailure(for:)`.
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

    /// Saves bound models while supplying the staged local files for asset
    /// fields. Asset leases remain owned by the caller and may be cleaned after
    /// this operation returns.
    public func save(
        assets: [CloudAssetMutationKey: CloudAssetUpload],
        atomic: Bool = true,
        retryPolicy: CloudRetryPolicy = .none
    ) async throws -> CloudModifyResult {
        activeSaveCount += 1
        defer {
            activeSaveCount -= 1
            reclaimRollbackMetadataIfPossible()
        }
        let rollbackGenerationsAtSaveStart = rollbackGenerations
        // Keep a before-request projection for every bound model, including a
        // model already marked for deletion. A rollback can restore that
        // model while the delete is in flight, and a direct setter made after
        // the rollback must be treated as an explicit recreation rather than
        // being silently removed when the successful delete response arrives.
        // This method is main-actor isolated and has not suspended yet, so the
        // same typed snapshots can feed staging without a second bridge pass.
        let snapshotsAtSaveStart: [CloudRecordIdentifier: CloudRecordSnapshot] =
            try Dictionary(uniqueKeysWithValues: models.map { id, model in
                try (id, model.cloudRecordSnapshot(in: zone))
            })
        let fieldsAtSaveStart = snapshotsAtSaveStart.mapValues(\.fields)
        try stageBoundModels(
            assets: assets,
            snapshotsAtSaveStart: snapshotsAtSaveStart
        )
        // Capture the exact model fields that entered the async request. A
        // bound model can still be edited by another main-actor callback while
        // CloudKit is in flight; direct property setters do not touch the
        // record-context revision counter. The post-save comparison below
        // preserves such an edit instead of applying the older server echo on
        // top of it.
        let fieldsSentByModel: [CloudRecordIdentifier: [CloudFieldIdentifier: CloudRecordValue]] =
            Dictionary(uniqueKeysWithValues: snapshotsAtSaveStart.compactMap { id, snapshot in
                guard recordContext.state(for: id) == .inserted ||
                    recordContext.state(for: id) == .dirty else { return nil }
                return (id, snapshot.fields)
            })
        let result = try await recordContext.save(
            assets: assets,
            atomic: atomic,
            retryPolicy: retryPolicy
        )
        var changedDuringSave = Set<CloudRecordIdentifier>()
        var currentSnapshotsByID = [CloudRecordIdentifier: CloudRecordSnapshot]()
        for snapshot in result.saved {
            guard let model = models[snapshot.id],
                  let sentFields = fieldsSentByModel[snapshot.id] else { continue }
            let current = try model.cloudRecordSnapshot(in: zone)
            currentSnapshotsByID[snapshot.id] = current
            if current.fields != sentFields {
                changedDuringSave.insert(snapshot.id)
            }
        }
        for snapshot in result.saved {
            guard let model = models[snapshot.id] else { continue }
            guard changedDuringSave.contains(snapshot.id) == false else { continue }
            let authoritative = recordContext.snapshot(for: snapshot.id)
            try model.applyCloudRecordSnapshot(authoritative ?? snapshot)
        }
        // Re-stage a direct edit that happened while the request was in
        // flight. The successful server snapshot is now the new ancestor, so
        // the next save uses its change tag and cannot be lost or overwritten.
        for id in changedDuringSave {
            guard let returned = result.saved.first(where: { $0.id == id }),
                  let current = currentSnapshotsByID[id] else { continue }
            // A newer typed save may already have committed the current model
            // fields while this request was in flight. Do not restage those
            // fields against the older raw response; the identity map is the
            // authoritative generation-filtered outcome.
            let server = recordContext.snapshot(for: id) ?? returned
            if server.fields == current.fields {
                continue
            }
            let removedFields = Set(server.fields.keys).subtracting(current.fields.keys)
            let policy: CloudRecordWritePolicy = if let changeTag = server.changeTag {
                .update(expectedChangeTag: changeTag)
            } else {
                .upsert
            }
            try recordContext.stage(
                CloudRecordMutation(
                    id: id,
                    modelID: current.modelID,
                    values: current.fields,
                    removedFields: removedFields,
                    policy: policy
                )
            )
        }
        for id in result.deleted {
            guard recordContext.state(for: id) == .deleted,
                  recordContext.snapshot(for: id) == nil else { continue }
            if let model = models[id],
               let fieldsAtStart = fieldsAtSaveStart[id]
            {
                let current = try model.cloudRecordSnapshot(in: zone)
                let rollbackGenerationChanged = (rollbackGenerations[id] ?? 0) >
                    (rollbackGenerationsAtSaveStart[id] ?? 0)
                let comparisonFields = rollbackGenerationChanged
                    ? rollbackRestoredFields[id]
                    : fieldsAtStart
                if current.fields != (comparisonFields ?? fieldsAtStart) {
                    // The remote delete won, but the user edited the bound
                    // model after rollback restored its baseline. Re-enter
                    // the identity map as a strict insert so a concurrent
                    // recreation produces an explicit conflict instead of a
                    // silent overwrite. Comparing with the rollback snapshot
                    // avoids treating a pre-delete edit that rollback erased
                    // as a new edit.
                    recordContext.discardChanges(for: id)
                    try recordContext.stage(CloudRecordMutation(
                        id: id,
                        modelID: current.modelID,
                        values: current.fields,
                        policy: .insert
                    ))
                    continue
                }
            }
            models.removeValue(forKey: id)
        }
        return result
    }

    /// Rolls back all local changes and reapplies the last server baselines to
    /// currently materialized models.
    public func rollback() throws {
        defer { reclaimRollbackMetadataIfPossible() }
        let ids = Array(models.keys)
        for id in ids {
            recordContext.discardChanges(for: id)
            guard let model = models[id], let baseline = recordContext.baseline(for: id) else {
                nextRollbackGeneration &+= 1
                rollbackGenerations[id] = nextRollbackGeneration
                rollbackRestoredFields.removeValue(forKey: id)
                continue
            }
            try model.applyCloudRecordSnapshot(baseline)
            nextRollbackGeneration &+= 1
            rollbackGenerations[id] = nextRollbackGeneration
            rollbackRestoredFields[id] = baseline.fields
        }
    }

    public func state<Model: CloudPersistentModel>(for model: Model) throws -> CloudModelState {
        try recordContext.state(for: model.cloudRecordIdentifier(in: zone))
    }

    public func snapshot<Model: CloudPersistentModel>(
        for model: Model
    ) throws -> CloudRecordSnapshot? {
        try recordContext.snapshot(for: model.cloudRecordIdentifier(in: zone))
    }

    public func conflict<Model: CloudPersistentModel>(
        for model: Model
    ) throws -> CloudConflict<Model>? {
        let id = try model.cloudRecordIdentifier(in: zone)
        guard let conflict = recordContext.conflict(for: id) else { return nil }
        return CloudConflict(model: model, record: conflict)
    }

    public func resolveConflict<Model: CloudPersistentModel>(
        for model: Model,
        using resolution: CloudConflictResolution
    ) throws {
        let id = try model.cloudRecordIdentifier(in: zone)
        try recordContext.resolveConflict(for: id, using: resolution)
        if case .useServer = resolution {
            if let server = recordContext.snapshot(for: id) {
                try model.applyCloudRecordSnapshot(server)
            } else {
                // The server no longer has the record and the caller accepted
                // that deletion. Unbind the model exactly as a completed
                // delete does, so the context no longer reports it as a
                // tracked model whose edits a later save would persist.
                models.removeValue(forKey: id)
            }
        } else if case .apply = resolution,
                  let current = recordContext.snapshot(for: id)
        {
            try model.applyCloudRecordSnapshot(current)
        }
    }

    private func materialize<Model: CloudPersistentModel>(
        _ snapshots: [CloudRecordSnapshot],
        as modelType: Model.Type,
        preservingLocalIDs: Set<CloudRecordIdentifier> = []
    ) throws -> [Model] {
        var result = [Model]()
        result.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            let materializedSnapshot = recordContext.snapshot(for: snapshot.id) ?? snapshot
            let model: Model
            if let existing = models[snapshot.id] {
                guard let typed = existing as? Model else {
                    throw try CloudModelRuntimeError.modelIdentifierMismatch(
                        expected: Model.cloudModelIdentifier(),
                        actual: snapshot.modelID
                    )
                }
                model = typed
                let state = recordContext.state(for: materializedSnapshot.id)
                if state == .clean,
                   preservingLocalIDs.contains(materializedSnapshot.id) == false
                {
                    try model.applyCloudRecordSnapshot(materializedSnapshot)
                } else if state == .dirty,
                          materializedSnapshot.isPartial == false,
                          let merged = recordContext.snapshot(for: materializedSnapshot.id),
                          merged.isPartial == false
                {
                    try model.applyCloudRecordSnapshot(merged)
                }
            } else {
                model = try Model.makeCloudModel(from: materializedSnapshot, in: zone)
                models[materializedSnapshot.id] = model
            }
            result.append(model)
        }
        return result
    }

    private func captureModelFields() throws -> [CloudRecordIdentifier: [CloudFieldIdentifier: CloudRecordValue]] {
        var fields = [CloudRecordIdentifier: [CloudFieldIdentifier: CloudRecordValue]]()
        for (id, model) in models {
            let state = recordContext.state(for: id)
            guard state != .detached else { continue }
            fields[id] = try model.cloudRecordSnapshot(in: zone).fields
        }
        return fields
    }

    private func captureModelFieldsForFetch() throws -> [CloudRecordIdentifier: [CloudFieldIdentifier: CloudRecordValue]] {
        var fields = [CloudRecordIdentifier: [CloudFieldIdentifier: CloudRecordValue]]()
        for (id, model) in models {
            let state = recordContext.state(for: id)
            guard state == .clean || state == .dirty else { continue }
            fields[id] = try model.cloudRecordSnapshot(in: zone).fields
        }
        return fields
    }

    private func captureFetchStartState() throws -> FetchStartCapture {
        var fields = [CloudRecordIdentifier: [CloudFieldIdentifier: CloudRecordValue]]()
        var edits = [CapturedModelEdit]()
        for (id, model) in models {
            let state = recordContext.state(for: id)
            guard state == .clean || state == .dirty else { continue }
            let local = try model.cloudRecordSnapshot(in: zone)
            fields[id] = local.fields
            guard let baseline = recordContext.snapshot(for: id) else { continue }
            if let edit = makeCapturedEdit(
                id: id,
                modelID: local.modelID,
                localFields: local.fields,
                baselineFields: baseline.fields
            ) {
                edits.append(edit)
            }
        }
        return FetchStartCapture(fields: fields, edits: edits)
    }

    private func captureDirectModelEditsRelativeToCurrentSnapshots() throws -> [CapturedModelEdit] {
        var edits = [CapturedModelEdit]()
        for (id, model) in models {
            let state = recordContext.state(for: id)
            guard state == .clean || state == .dirty,
                  let baseline = recordContext.snapshot(for: id) else { continue }
            let local = try model.cloudRecordSnapshot(in: zone)
            if let edit = makeCapturedEdit(
                id: id,
                modelID: local.modelID,
                localFields: local.fields,
                baselineFields: baseline.fields
            ) {
                edits.append(edit)
            }
        }
        return edits
    }

    private func captureDirectModelEditsMadeSince(
        _ starts: [CloudRecordIdentifier: [CloudFieldIdentifier: CloudRecordValue]],
        includingDirtyModels: Bool = false
    ) throws -> [CapturedModelEdit] {
        var edits = [CapturedModelEdit]()
        for (id, startFields) in starts {
            let state = recordContext.state(for: id)
            guard state == .clean || (includingDirtyModels && state == .dirty),
                  let model = models[id] else { continue }
            let local = try model.cloudRecordSnapshot(in: zone)
            if let edit = makeCapturedEdit(
                id: id,
                modelID: local.modelID,
                localFields: local.fields,
                baselineFields: startFields
            ) {
                edits.append(edit)
            }
        }
        return edits
    }

    private func makeCapturedEdit(
        id: CloudRecordIdentifier,
        modelID: CloudModelIdentifier,
        localFields: [CloudFieldIdentifier: CloudRecordValue],
        baselineFields: [CloudFieldIdentifier: CloudRecordValue]
    ) -> CapturedModelEdit? {
        var values = [CloudFieldIdentifier: CloudRecordValue]()
        for (fieldID, value) in localFields where baselineFields[fieldID] != value {
            values[fieldID] = value
        }
        let removedFields = Set(baselineFields.keys).subtracting(localFields.keys)
        guard values.isEmpty == false || removedFields.isEmpty == false else { return nil }
        return CapturedModelEdit(
            id: id,
            modelID: modelID,
            values: values,
            removedFields: removedFields
        )
    }

    private func mergeCapturedEdits(
        _ initial: [CapturedModelEdit],
        with later: [CapturedModelEdit]
    ) -> [CapturedModelEdit] {
        var merged = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0) })
        for edit in later {
            guard var existing = merged[edit.id] else {
                merged[edit.id] = edit
                continue
            }
            var values = existing.values
            var removedFields = existing.removedFields
            for fieldID in edit.removedFields {
                values.removeValue(forKey: fieldID)
                removedFields.insert(fieldID)
            }
            for (fieldID, value) in edit.values {
                removedFields.remove(fieldID)
                values[fieldID] = value
            }
            existing = CapturedModelEdit(
                id: existing.id,
                modelID: edit.modelID,
                values: values,
                removedFields: removedFields
            )
            merged[edit.id] = existing
        }
        return merged.values.sorted { $0.id < $1.id }
    }

    private func reconcileCapturedEdits(
        _ edits: [CapturedModelEdit],
        against snapshots: [CloudRecordSnapshot]
    ) -> [CapturedModelEdit] {
        edits.compactMap { edit in
            let state = recordContext.state(for: edit.id)
            guard state != .deleted, state != .detached else {
                // A local delete/detach that wins while the request is in
                // flight supersedes any older direct setter. Do not attempt
                // to re-stage that stale edit after the fetch completes.
                return nil
            }
            guard let pageSnapshot = snapshots.first(where: { $0.id == edit.id }) else {
                return edit
            }
            let server = recordContext.snapshot(for: edit.id) ?? pageSnapshot
            guard server.isPartial == false else { return edit }
            if state == .dirty {
                // A dirty partial baseline already has a pending mutation.
                // Keep the newer direct value even when it happens to equal
                // the full server field; otherwise materialization would
                // replay the older pending value over the user's latest one.
                return edit
            }
            let values = edit.values.filter { fieldID, value in
                server.fields[fieldID] != value
            }
            let removedFields = Set(edit.removedFields.filter {
                server.fields[$0] != nil
            })
            guard values.isEmpty == false || removedFields.isEmpty == false else {
                return nil
            }
            return CapturedModelEdit(
                id: edit.id,
                modelID: edit.modelID,
                values: values,
                removedFields: removedFields
            )
        }
    }

    private func rebaseCapturedEdits(
        _ edits: [CapturedModelEdit],
        onto snapshots: [CloudRecordSnapshot]
    ) throws {
        for edit in edits {
            let state = recordContext.state(for: edit.id)
            guard state != .deleted, state != .detached else { continue }
            guard let pageSnapshot = snapshots.first(where: { $0.id == edit.id }) else { continue }
            let server = recordContext.snapshot(for: edit.id) ?? pageSnapshot
            let policy: CloudRecordWritePolicy = if recordContext.state(for: edit.id) == .dirty,
                                                    recordContext.baseline(for: edit.id)?.isPartial == false,
                                                    let pending = recordContext.pendingMutation(for: edit.id)
            {
                // A full fetch must retain the original optimistic policy for
                // an already-dirty record. Replaying a direct setter should
                // not turn a potential server conflict into an implicit
                // last-writer-wins update.
                pending.policy
            } else if let changeTag = server.changeTag {
                .update(expectedChangeTag: changeTag)
            } else {
                .upsert
            }
            try recordContext.stage(
                CloudRecordMutation(
                    id: edit.id,
                    modelID: edit.modelID,
                    values: edit.values,
                    removedFields: edit.removedFields,
                    policy: policy
                )
            )
        }
    }

    private func reapplyCapturedEdits(
        _ edits: [CapturedModelEdit],
        onto snapshots: [CloudRecordSnapshot]
    ) throws {
        for edit in edits {
            let state = recordContext.state(for: edit.id)
            guard state != .deleted, state != .detached else { continue }
            guard let pageSnapshot = snapshots.first(where: { $0.id == edit.id }) else { continue }
            let server = recordContext.snapshot(for: edit.id) ?? pageSnapshot
            guard server.isPartial == false,
                  let model = models[edit.id] else { continue }
            var fields = server.fields
            for (fieldID, value) in edit.values {
                fields[fieldID] = value
            }
            for fieldID in edit.removedFields {
                fields.removeValue(forKey: fieldID)
            }
            try model.applyCloudRecordSnapshot(CloudRecordSnapshot(
                id: server.id,
                modelID: server.modelID,
                changeTag: server.changeTag,
                fields: fields
            ))
        }
    }

    private func stageBoundModels(
        assets: [CloudAssetMutationKey: CloudAssetUpload] = [:],
        snapshotsAtSaveStart: [CloudRecordIdentifier: CloudRecordSnapshot]
    ) throws {
        for (id, model) in models {
            let state = recordContext.state(for: id)
            guard state == .inserted || state == .dirty || state == .clean else { continue }
            let snapshot = try snapshotsAtSaveStart[id] ?? model.cloudRecordSnapshot(in: zone)
            guard snapshot.id == id else {
                throw CloudModelRuntimeError.invalidSnapshot(
                    id,
                    reason: "a bound model changed its record identifier"
                )
            }
            var values = snapshot.fields
            // The generated legacy backing layer may expose an asset through a
            // temporary CKAsset path whose filename is not the managed stager's
            // reference ID. The explicit field binding is authoritative for a
            // typed save, so replace only the bound asset fields before the
            // mutation reaches the CloudKit adapter.
            for (key, upload) in assets where key.recordID == id {
                values[key.fieldID] = .asset(upload.reference)
            }
            let baseline = recordContext.baseline(for: id)
            let current = recordContext.snapshot(for: id)
            let baselineFields = baseline.map { Set($0.fields.keys) } ?? []
            let currentFields = current.map { Set($0.fields.keys) } ?? []
            let candidateFields = baselineFields.union(currentFields)
            let removedFields = candidateFields.filter {
                values[$0] == nil
            }
            let policy: CloudRecordWritePolicy
            switch state {
            case .inserted:
                policy = .insert
            case .dirty, .clean:
                let hasChanges = values != (current?.fields ?? [:]) || removedFields.isEmpty == false
                if hasChanges, baseline?.isPartial == true {
                    throw CloudContextError.partialSnapshotRequiresFullFetch(id)
                }
                guard let baseline, baseline.changeTag != nil else {
                    if hasChanges == false { continue }
                    policy = .upsert
                    break
                }
                if hasChanges == false { continue }
                policy = .update(expectedChangeTag: baseline.changeTag ?? "")
            case .detached, .deleted:
                continue
            }
            var mutationValues = values
            if case .update = policy {
                // An update sends only what changed. Resending an untouched
                // remote asset would require a fresh upload for it, and the
                // server keeps every field that is not mentioned.
                let uploaded = Set(
                    assets.keys.filter { $0.recordID == id }.map(\.fieldID)
                )
                let currentFields = current?.fields ?? [:]
                mutationValues = values.filter {
                    uploaded.contains($0.key) || currentFields[$0.key] != $0.value
                }
            }
            try recordContext.stage(
                CloudRecordMutation(
                    id: id,
                    modelID: snapshot.modelID,
                    values: mutationValues,
                    removedFields: removedFields,
                    policy: policy
                )
            )
        }
    }

    private func reclaimRollbackMetadataIfPossible() {
        guard activeSaveCount == 0 else { return }
        // Rollback metadata is only needed to compare a rollback that occurs
        // while a typed save is in flight. Once the last save has finished,
        // the next save captures the current model fields as its own baseline
        // and does not need historical generations or field dictionaries.
        rollbackGenerations.removeAll(keepingCapacity: false)
        rollbackRestoredFields.removeAll(keepingCapacity: false)
    }
}

/// A complete container assembled from an immutable schema and injected
/// database client. No CloudKit singleton is created implicitly.
@MainActor
public final class CloudModelContainer {
    public let schema: CloudSchema
    public let configuration: CloudStoreConfiguration
    public let store: CloudKitRecordStore
    public let recordContext: CloudRecordContext
    public let mainContext: CloudModelContext

    public init(
        schema: CloudSchema,
        configuration: CloudStoreConfiguration,
        client: any CloudDatabaseClient
    ) throws {
        self.schema = schema
        self.configuration = configuration
        store = CloudKitRecordStore(
            schema: schema,
            configuration: configuration,
            client: client
        )
        recordContext = CloudRecordContext(store: store)
        mainContext = try CloudModelContext(
            recordContext: recordContext,
            zone: configuration.recordZoneIdentifier()
        )
    }
}

public extension CloudStoreConfiguration {
    /// Returns the record zone represented by this store location. Public
    /// databases use a stable synthetic zone because CloudKit public records
    /// are not owned by a private custom zone.
    func recordZoneIdentifier() throws -> CloudZoneIdentifier {
        switch location {
        case .publicDatabase:
            try CloudZoneIdentifier("public")
        case let .privateDatabase(zone):
            switch zone {
            case .default:
                try CloudZoneIdentifier("_defaultZone")
            case let .custom(identifier):
                identifier
            }
        case let .sharedDatabase(zone):
            switch zone {
            case let .custom(identifier):
                identifier
            }
        }
    }
}
