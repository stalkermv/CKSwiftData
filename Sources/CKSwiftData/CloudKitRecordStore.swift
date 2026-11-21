import Foundation

/// The actor-isolated persistence facade. It validates requests against the
/// immutable schema before delegating to the injected client.
public actor CloudKitRecordStore {
    public nonisolated let schema: CloudSchema
    public nonisolated let configuration: CloudStoreConfiguration

    private let client: any CloudDatabaseClient

    public init(
        schema: CloudSchema,
        configuration: CloudStoreConfiguration,
        client: any CloudDatabaseClient
    ) {
        self.schema = schema
        self.configuration = configuration
        self.client = client
    }

    public func fetch(_ request: CloudRecordFetchRequest) async throws -> CloudRecordPage {
        try await fetch(request, retryPolicy: .none)
    }

    public func fetch(
        _ request: CloudRecordFetchRequest,
        retryPolicy: CloudRetryPolicy
    ) async throws -> CloudRecordPage {
        guard schema.model(request.modelID) != nil else {
            throw CloudContextError.unknownModel(request.modelID)
        }
        return try await performWithRetry(retryPolicy) {
            try await self.client.fetch(request)
        }
    }

    public func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        atomic: Bool = true
    ) async throws -> CloudModifyResult {
        try await modify(
            saving: mutations,
            deleting: recordIDs,
            atomic: atomic,
            retryPolicy: .none
        )
    }

    public func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        atomic: Bool = true,
        retryPolicy: CloudRetryPolicy
    ) async throws -> CloudModifyResult {
        for mutation in mutations {
            try validateMutation(mutation)
        }
        try validateZone(mutations: mutations, recordIDs: recordIDs)
        return try await performWithRetry(retryPolicy) {
            try await self.client.modify(
                saving: mutations,
                deleting: recordIDs,
                atomic: atomic
            )
        }
    }

    /// Persists mutations that reference staged CloudKit assets. The asset
    /// overload is explicit so an injected fake cannot accidentally receive
    /// local file URLs it does not understand.
    public func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        assets: [CloudAssetMutationKey: CloudAssetUpload],
        atomic: Bool = true,
        retryPolicy: CloudRetryPolicy = .none
    ) async throws -> CloudModifyResult {
        guard assets.isEmpty || client is CloudKitDatabaseClient else {
            throw CloudModelError.unsupported(
                "staged assets require CloudKitDatabaseClient"
            )
        }
        for mutation in mutations {
            try validateMutation(mutation)
        }
        try validateZone(mutations: mutations, recordIDs: recordIDs)
        guard let cloudKitClient = client as? CloudKitDatabaseClient else {
            return try await modify(
                saving: mutations,
                deleting: recordIDs,
                atomic: atomic,
                retryPolicy: retryPolicy
            )
        }
        return try await performWithRetry(retryPolicy) {
            try await cloudKitClient.modify(
                saving: mutations,
                deleting: recordIDs,
                assets: assets,
                atomic: atomic
            )
        }
    }

    public func delete(
        _ recordIDs: [CloudRecordIdentifier],
        atomic: Bool = true,
        retryPolicy: CloudRetryPolicy = .none
    ) async throws -> CloudModifyResult {
        try await modify(
            saving: [],
            deleting: recordIDs,
            atomic: atomic,
            retryPolicy: retryPolicy
        )
    }

    private func performWithRetry<Result: Sendable>(
        _ policy: CloudRetryPolicy,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CloudModelError.cancelled
            } catch let error as CloudModelError where error.isRetryable {
                guard attempt < policy.maxAttempts else { throw error }
                let delay = policy.delay(
                    beforeAttempt: attempt,
                    serverRetryAfter: error.retryAfter
                )
                do {
                    try Task.checkCancellation()
                    if delay > 0 {
                        let nanoseconds = UInt64(min(delay, 9_223_372_036.0) * 1_000_000_000)
                        try await Task.sleep(nanoseconds: nanoseconds)
                    }
                } catch is CancellationError {
                    throw CloudModelError.cancelled
                }
                attempt += 1
            }
        }
    }

    private func validateZone(
        mutations: [CloudRecordMutation],
        recordIDs: [CloudRecordIdentifier]
    ) throws {
        let expectedZone = try configuration.recordZoneIdentifier()
        for mutation in mutations where mutation.id.zone != expectedZone {
            throw CloudContextError.invalidZone(
                expected: expectedZone,
                actual: mutation.id.zone
            )
        }
        for id in recordIDs where id.zone != expectedZone {
            throw CloudContextError.invalidZone(expected: expectedZone, actual: id.zone)
        }
    }

    private func validateMutation(_ mutation: CloudRecordMutation) throws {
        guard let model = schema.model(mutation.modelID) else {
            throw CloudContextError.unknownModel(mutation.modelID)
        }
        try model.validate(mutation: mutation)
    }
}
