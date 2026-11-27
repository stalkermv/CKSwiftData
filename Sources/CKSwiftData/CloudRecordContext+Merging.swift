import Foundation

@MainActor
extension CloudRecordContext {
    public func conflict(for id: CloudRecordIdentifier) -> CloudRecordConflict? {
        conflicts[id]
    }

    /// Applies an explicit conflict decision. No merge policy is hidden in the
    /// context: callers choose server, client, or a complete replacement
    /// mutation and can then call `save` again.
    public func resolveConflict(
        for id: CloudRecordIdentifier,
        using resolution: CloudConflictResolution
    ) throws {
        guard let conflict = conflicts[id] else {
            throw CloudContextError.missingConflictServerSnapshot(id)
        }
        switch resolution {
        case .useServer:
            guard let server = conflict.server else {
                snapshots.removeValue(forKey: id)
                baselines.removeValue(forKey: id)
                stagedMutations.removeValue(forKey: id)
                stagedDeletes.remove(id)
                states[id] = .deleted
                failures.removeValue(forKey: id)
                conflicts.removeValue(forKey: id)
                bumpRevision(for: id)
                return
            }
            snapshots[id] = server
            baselines[id] = server
            stagedMutations.removeValue(forKey: id)
            stagedDeletes.remove(id)
            states[id] = .clean
            failures.removeValue(forKey: id)
            conflicts.removeValue(forKey: id)
            bumpRevision(for: id)
        case .useClient:
            let client = conflict.client
            stagedMutations.removeValue(forKey: id)
            stagedDeletes.remove(id)
            let mutation: CloudRecordMutation
            if let server = conflict.server {
                guard let changeTag = server.changeTag else {
                    throw CloudContextError.missingConflictServerSnapshot(id)
                }
                let removed = Set(server.fields.keys).subtracting(client.fields.keys)
                mutation = try CloudRecordMutation(
                    id: id,
                    modelID: client.modelID,
                    values: client.fields,
                    removedFields: removed,
                    policy: .update(expectedChangeTag: changeTag)
                )
            } else {
                mutation = try CloudRecordMutation(
                    id: id,
                    modelID: client.modelID,
                    values: client.fields,
                    policy: .insert
                )
            }
            try stage(mutation)
            conflicts.removeValue(forKey: id)
        case let .apply(mutation):
            guard mutation.id == id else {
                throw CloudContextError.recordBelongsToAnotherModel(
                    id,
                    expected: mutation.modelID,
                    actual: conflict.client.modelID
                )
            }
            stagedMutations.removeValue(forKey: id)
            stagedDeletes.remove(id)
            try stage(mutation)
            conflicts.removeValue(forKey: id)
        }
    }

    @discardableResult
    func mergeFetched(_ snapshot: CloudRecordSnapshot) -> Bool {
        guard let currentState = states[snapshot.id] else {
            snapshots[snapshot.id] = snapshot
            baselines[snapshot.id] = snapshot
            states[snapshot.id] = .clean
            failures.removeValue(forKey: snapshot.id)
            conflicts.removeValue(forKey: snapshot.id)
            return true
        }

        if currentState == .detached {
            // A discard refresh can detach an inserted or deleted local
            // record that had no server baseline. If the page contains a
            // remote record with the same identifier, treat it as a fresh
            // attachment instead of silently returning a stale local object.
            snapshots[snapshot.id] = snapshot
            baselines[snapshot.id] = snapshot
            states[snapshot.id] = .clean
            failures.removeValue(forKey: snapshot.id)
            conflicts.removeValue(forKey: snapshot.id)
            return true
        }

        guard currentState == .clean else {
            guard currentState == .dirty,
                  snapshot.isPartial == false,
                  baselines[snapshot.id]?.isPartial == true,
                  let pending = stagedMutations[snapshot.id] else { return false }
            // A full fetch can arrive after a partial fetch has already
            // staged a local field edit. Promote the full server record to the
            // new ancestor, then replay only the pending mutation over it and
            // rebase its change-tag policy. This lets typed materialization
            // observe remote changes in untouched fields without losing the
            // local edit.
            var fields = snapshot.fields
            for fieldID in pending.removedFields {
                fields.removeValue(forKey: fieldID)
            }
            for (fieldID, value) in pending.values {
                fields[fieldID] = value
            }
            if let merged = try? CloudRecordSnapshot(
                id: snapshot.id,
                modelID: snapshot.modelID,
                changeTag: snapshot.changeTag,
                fields: fields,
                isPartial: false
            ) {
                baselines[snapshot.id] = snapshot
                snapshots[snapshot.id] = merged
                stagedMutations[snapshot.id] = rebased(pending, onto: snapshot)
                failures.removeValue(forKey: snapshot.id)
                conflicts.removeValue(forKey: snapshot.id)
                return true
            }
            return false
        }
        if snapshot.isPartial {
            // A projected CloudKit record carries the current change tag but
            // intentionally omits every field outside desiredFields. Merge
            // its known values into the identity map, while retaining the
            // partial marker so a typed full-model save cannot mistake stale
            // omitted values for a complete server baseline.
            let current = snapshots[snapshot.id]
            let baseline = baselines[snapshot.id] ?? current
            snapshots[snapshot.id] = mergedPartialSnapshot(snapshot, onto: current)
            baselines[snapshot.id] = mergedPartialSnapshot(snapshot, onto: baseline)
        } else {
            snapshots[snapshot.id] = snapshot
            baselines[snapshot.id] = snapshot
        }
        failures.removeValue(forKey: snapshot.id)
        conflicts.removeValue(forKey: snapshot.id)
        return true
    }

    /// Applies the server result of an explicit discard refresh while retaining
    /// only mutations created after that refresh began. A revision change alone
    /// is too coarse here: an overlapping typed fetch can stage a newer field
    /// edit alongside an older pending mutation that the discard must remove.
    func mergeDiscardedFetched(
        _ snapshot: CloudRecordSnapshot,
        startingMutation: CloudRecordMutation?,
        hadStartingDelete: Bool
    ) throws {
        let currentMutation = stagedMutations[snapshot.id]
        let postDiscardMutation = mutationDelta(
            from: startingMutation,
            to: currentMutation
        )
        let postDiscardDelete = stagedDeletes.contains(snapshot.id) && !hadStartingDelete

        discardChanges(for: snapshot.id)
        mergeFetched(snapshot)

        if postDiscardDelete {
            try delete(snapshot.id)
        } else if let postDiscardMutation {
            let values = postDiscardMutation.values.filter { fieldID, value in
                snapshot.fields[fieldID] != value
            }
            let removedFields = postDiscardMutation.removedFields.filter {
                snapshot.fields[$0] != nil
            }
            guard values.isEmpty == false || removedFields.isEmpty == false else {
                return
            }
            let policy: CloudRecordWritePolicy = if let changeTag = snapshot.changeTag {
                .update(expectedChangeTag: changeTag)
            } else {
                .upsert
            }
            try stage(CloudRecordMutation(
                id: snapshot.id,
                modelID: postDiscardMutation.modelID,
                values: values,
                removedFields: removedFields,
                policy: policy
            ))
        }
    }

    private func mutationDelta(
        from starting: CloudRecordMutation?,
        to current: CloudRecordMutation?
    ) -> CloudRecordMutation? {
        guard let current else { return nil }
        var fieldIDs = Set<CloudFieldIdentifier>()
        if let starting {
            fieldIDs.formUnion(starting.values.keys)
            fieldIDs.formUnion(starting.removedFields)
        }
        fieldIDs.formUnion(current.values.keys)
        fieldIDs.formUnion(current.removedFields)
        var values = [CloudFieldIdentifier: CloudRecordValue]()
        var removedFields = Set<CloudFieldIdentifier>()
        for fieldID in fieldIDs {
            let startingState = mutationFieldState(starting, fieldID: fieldID)
            let currentState = mutationFieldState(current, fieldID: fieldID)
            guard startingState != currentState else { continue }
            switch currentState {
            case let .value(value): values[fieldID] = value
            case .removed: removedFields.insert(fieldID)
            case .absent: break
            }
        }
        guard values.isEmpty == false || removedFields.isEmpty == false else { return nil }
        return try? CloudRecordMutation(
            id: current.id,
            modelID: current.modelID,
            values: values,
            removedFields: removedFields,
            policy: current.policy
        )
    }

    private enum MutationFieldState: Equatable {
        case absent
        case value(CloudRecordValue)
        case removed
    }

    private func mutationFieldState(
        _ mutation: CloudRecordMutation?,
        fieldID: CloudFieldIdentifier
    ) -> MutationFieldState {
        guard let mutation else { return .absent }
        if let value = mutation.values[fieldID] { return .value(value) }
        if mutation.removedFields.contains(fieldID) { return .removed }
        return .absent
    }

    private func mergedPartialSnapshot(
        _ incoming: CloudRecordSnapshot,
        onto existing: CloudRecordSnapshot?
    ) -> CloudRecordSnapshot {
        guard let existing else { return incoming }
        var fields = existing.fields
        fields.merge(incoming.fields) { _, incoming in incoming }
        // All inputs have already passed CloudRecordSnapshot validation. The
        // only throwing condition is an empty change tag, which cannot be
        // produced by a valid incoming snapshot; retain the incoming value as
        // a defensive fallback if a custom implementation violates it.
        return (try? CloudRecordSnapshot(
            id: incoming.id,
            modelID: incoming.modelID,
            changeTag: incoming.changeTag ?? existing.changeTag,
            fields: fields,
            isPartial: true
        )) ?? incoming
    }

    func mergeFetchFailures(
        _ failures: [CloudRecordFailure],
        generation: UInt64,
        startingRevisions: [CloudRecordIdentifier: UInt64],
        startingStates: [CloudRecordIdentifier: CloudModelState]
    ) {
        for failure in failures {
            let revisionAtStart = startingRevisions[failure.id] ?? 0
            let revisionNow = revisions[failure.id] ?? 0
            let stateAtStart = startingStates[failure.id] ?? .detached
            let stateNow = states[failure.id] ?? .detached
            guard revisionAtStart == revisionNow,
                  stateAtStart == stateNow,
                  acceptFetchGeneration(for: failure.id, generation: generation)
            else {
                continue
            }
            self.failures[failure.id] = failure.error
            if let conflict = failure.conflict {
                conflicts[failure.id] = conflict
            }
        }
    }

    func mergeSaveResult(
        _ result: CloudModifyResult,
        capturedRevisions: [CloudRecordIdentifier: UInt64],
        capturedGenerations: [CloudRecordIdentifier: UInt64],
        capturedDiscardEpochs: [CloudRecordIdentifier: UInt64],
        capturedBaselines: [CloudRecordIdentifier: CloudRecordSnapshot],
        capturedSnapshots: [CloudRecordIdentifier: CloudRecordSnapshot]
    ) {
        for snapshot in result.saved {
            let id = snapshot.id
            guard revisions[id] != nil else { continue }
            guard let generation = capturedGenerations[id],
                  (discardBarrierEpochs[id] ?? 0) <= (capturedDiscardEpochs[id] ?? 0),
                  acceptSaveGeneration(for: id, generation: generation)
            else {
                continue
            }
            guard revisions[id] == capturedRevisions[id] else {
                // A low-level caller may stage another mutation while the
                // previous request is in flight. The server result is still
                // the new ancestor, but the pending mutation must be rebased
                // onto its change tag; otherwise an earlier `.insert` or
                // `.update` policy would self-conflict on the next retry.
                // An explicit `detach` removes the revision entirely, so its
                // in-flight result must not resurrect an identity-map entry.
                guard revisions[id] != nil else { continue }
                guard hasNewerAuthoritativeSnapshot(
                    for: id,
                    capturedBaseline: capturedBaselines[id],
                    capturedSnapshot: capturedSnapshots[id],
                    matching: snapshot
                ) == false else { continue }
                baselines[id] = snapshot
                if let pending = stagedMutations[id] {
                    stagedMutations[id] = rebased(
                        pending,
                        onto: snapshot
                    )
                    if let current = snapshots[id] {
                        snapshots[id] = (try? CloudRecordSnapshot(
                            id: current.id,
                            modelID: current.modelID,
                            changeTag: snapshot.changeTag,
                            fields: current.fields,
                            isPartial: current.isPartial
                        )) ?? current
                    }
                    states[id] = .dirty
                } else {
                    // Rollback/discard can finish while an insert or update
                    // is already committed remotely. The response cannot be
                    // undone; promote it to the current local baseline so a
                    // bound model remains tracked instead of becoming a
                    // detached, silent no-op on its next edit. Preserve a
                    // newer local delete intent when one is staged.
                    snapshots[id] = snapshot
                    states[id] = stagedDeletes.contains(id) ? .deleted : .clean
                    failures.removeValue(forKey: id)
                    conflicts.removeValue(forKey: id)
                }
                latestCommittedSaveGenerations[id] = generation
                continue
            }
            snapshots[id] = snapshot
            baselines[id] = snapshot
            states[id] = .clean
            stagedMutations.removeValue(forKey: id)
            stagedDeletes.remove(id)
            failures.removeValue(forKey: id)
            conflicts.removeValue(forKey: id)
            latestCommittedSaveGenerations[id] = generation
        }

        for id in result.deleted {
            guard revisions[id] != nil else { continue }
            guard let generation = capturedGenerations[id],
                  (discardBarrierEpochs[id] ?? 0) <= (capturedDiscardEpochs[id] ?? 0),
                  acceptSaveGeneration(for: id, generation: generation)
            else {
                continue
            }
            guard revisions[id] == capturedRevisions[id] ||
                (stagedMutations[id] == nil &&
                    hasNewerAuthoritativeSnapshot(
                        for: id,
                        capturedBaseline: capturedBaselines[id],
                        capturedSnapshot: capturedSnapshots[id]
                    ) == false) else { continue }
            snapshots.removeValue(forKey: id)
            baselines.removeValue(forKey: id)
            stagedMutations.removeValue(forKey: id)
            stagedDeletes.remove(id)
            states[id] = .deleted
            failures.removeValue(forKey: id)
            conflicts.removeValue(forKey: id)
            latestCommittedSaveGenerations[id] = generation
        }

        for failure in result.failures {
            guard revisions[failure.id] != nil else { continue }
            guard let generation = capturedGenerations[failure.id],
                  (discardBarrierEpochs[failure.id] ?? 0) <= (capturedDiscardEpochs[failure.id] ?? 0),
                  revisions[failure.id] == capturedRevisions[failure.id],
                  acceptSaveGeneration(for: failure.id, generation: generation)
            else {
                continue
            }
            failures[failure.id] = failure.error
            if let conflict = failure.conflict {
                let client = snapshots[failure.id] ?? conflict.client
                conflicts[failure.id] = conflict
                    .with(client: client, ancestor: baselines[failure.id])
            } else if case .conflict = failure.error,
                      let client = snapshots[failure.id]
            {
                conflicts[failure.id] = CloudRecordConflict(
                    id: failure.id,
                    ancestor: baselines[failure.id],
                    client: client
                )
            }
            if states[failure.id] != .deleted {
                states[failure.id] = snapshots[failure.id] == nil ? .inserted : .dirty
            }
        }
    }

    private func hasNewerAuthoritativeSnapshot(
        for id: CloudRecordIdentifier,
        capturedBaseline: CloudRecordSnapshot?,
        capturedSnapshot: CloudRecordSnapshot?,
        matching candidate: CloudRecordSnapshot? = nil
    ) -> Bool {
        guard let current = baselines[id] else { return false }
        if let candidate, sameAuthoritativeVersion(current, candidate) {
            return false
        }
        let captured = capturedBaseline ?? capturedSnapshot
        guard let captured else { return false }

        // A projection changes the shape of a snapshot without changing the
        // CloudKit version. Compare change tags first so an old projected
        // response with the same tag cannot suppress an in-flight save.
        return sameAuthoritativeVersion(current, captured) == false
    }

    private func sameAuthoritativeVersion(
        _ lhs: CloudRecordSnapshot,
        _ rhs: CloudRecordSnapshot
    ) -> Bool {
        if let currentTag = lhs.changeTag,
           let capturedTag = rhs.changeTag
        {
            return currentTag == capturedTag
        }
        if lhs.changeTag != rhs.changeTag {
            return false
        }

        // Untagged records are normally inserts. When both sides are complete
        // snapshots, their fields are the only remaining authoritative
        // identity. Ignore projection shape and fields when either side is
        // partial because omitted values cannot establish a newer version.
        guard lhs.isPartial == false, rhs.isPartial == false else {
            return false
        }
        return lhs.fields == rhs.fields
    }

    private func rebased(
        _ mutation: CloudRecordMutation,
        onto snapshot: CloudRecordSnapshot
    ) -> CloudRecordMutation {
        let policy: CloudRecordWritePolicy = switch mutation.policy {
        case .insert, .update:
            if let changeTag = snapshot.changeTag {
                .update(expectedChangeTag: changeTag)
            } else {
                .upsert
            }
        case .upsert:
            .upsert
        }
        return (try? CloudRecordMutation(
            id: mutation.id,
            modelID: mutation.modelID,
            values: mutation.values,
            removedFields: mutation.removedFields,
            policy: policy
        )) ?? mutation
    }

    func merge(
        _ incoming: CloudRecordMutation,
        with previous: CloudRecordMutation?
    ) throws -> CloudRecordMutation {
        guard let previous else { return incoming }
        guard previous.modelID == incoming.modelID else {
            throw CloudContextError.recordBelongsToAnotherModel(
                incoming.id,
                expected: incoming.modelID,
                actual: previous.modelID
            )
        }

        var values = previous.values
        var removed = previous.removedFields
        for field in incoming.removedFields {
            values.removeValue(forKey: field)
            removed.insert(field)
        }
        for (field, value) in incoming.values {
            removed.remove(field)
            values[field] = value
        }
        let policy: CloudRecordWritePolicy = switch (previous.policy, incoming.policy) {
        case (.insert, _): .insert
        case (_, .insert): .insert
        case let (.update(tag), _): .update(expectedChangeTag: tag)
        case let (_, .update(tag)): .update(expectedChangeTag: tag)
        case (.upsert, .upsert): .upsert
        }
        return try CloudRecordMutation(
            id: incoming.id,
            modelID: incoming.modelID,
            values: values,
            removedFields: removed,
            policy: policy
        )
    }

    func bumpRevision(for id: CloudRecordIdentifier) {
        nextRevision &+= 1
        revisions[id] = nextRevision
    }

    func beginFetchGeneration() -> UInt64 {
        nextFetchGeneration &+= 1
        return nextFetchGeneration
    }

    func acceptFetchGeneration(
        for id: CloudRecordIdentifier,
        generation: UInt64
    ) -> Bool {
        guard generation >= (latestFetchGenerations[id] ?? 0) else { return false }
        latestFetchGenerations[id] = generation
        return true
    }

    func acceptDiscardFetchGeneration(
        for id: CloudRecordIdentifier,
        generation: UInt64
    ) -> Bool {
        guard generation >= (latestDiscardFetchGenerations[id] ?? 0) else {
            return false
        }
        latestDiscardFetchGenerations[id] = generation
        return true
    }

    func shouldSkipOrdinaryFetch(
        for id: CloudRecordIdentifier,
        discardEpochAtStart: UInt64,
        discardWasInFlightAtStart: Bool
    ) -> Bool {
        guard let barrierEpoch = discardBarrierEpochs[id] else { return false }
        return barrierEpoch > discardEpochAtStart ||
            (discardWasInFlightAtStart && barrierEpoch == discardEpochAtStart)
    }

    func beginSaveGeneration() -> UInt64 {
        nextSaveGeneration &+= 1
        return nextSaveGeneration
    }

    func acceptSaveGeneration(
        for id: CloudRecordIdentifier,
        generation: UInt64
    ) -> Bool {
        guard generation >= (latestSaveGenerations[id] ?? 0) else { return false }
        latestSaveGenerations[id] = generation
        return true
    }
}
