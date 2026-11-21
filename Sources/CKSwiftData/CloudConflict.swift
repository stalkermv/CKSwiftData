import Foundation

/// Immutable three-way conflict information. `server` is nil when the record
/// disappeared before the conflict was reported.
public struct CloudRecordConflict: Codable, Hashable, Sendable {
    public let id: CloudRecordIdentifier
    public let ancestor: CloudRecordSnapshot?
    public let client: CloudRecordSnapshot
    public let server: CloudRecordSnapshot?

    public init(
        id: CloudRecordIdentifier,
        ancestor: CloudRecordSnapshot? = nil,
        client: CloudRecordSnapshot,
        server: CloudRecordSnapshot? = nil
    ) {
        self.id = id
        self.ancestor = ancestor
        self.client = client
        self.server = server
    }

    func with(
        client: CloudRecordSnapshot,
        ancestor: CloudRecordSnapshot?
    ) -> CloudRecordConflict {
        CloudRecordConflict(
            id: id,
            ancestor: ancestor ?? self.ancestor,
            client: client,
            server: server
        )
    }
}

public enum CloudConflictResolution: Codable, Hashable, Sendable {
    case useServer
    case useClient
    case apply(CloudRecordMutation)
}

public protocol CloudConflictResolver: Sendable {
    func resolve(_ conflict: CloudRecordConflict) async throws -> CloudConflictResolution
}

/// A conflict paired with a materialized model for UI- or domain-level
/// resolution. The immutable record conflict remains the source of truth.
public struct CloudConflict<Model: CloudPersistentModel> {
    public let model: Model
    public let record: CloudRecordConflict

    public init(model: Model, record: CloudRecordConflict) {
        self.model = model
        self.record = record
    }
}
