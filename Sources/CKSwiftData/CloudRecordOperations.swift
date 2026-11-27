import Foundation

/// A bounded fetch request. The cursor is opaque to callers and owned by the store.
public struct CloudRecordFetchRequest: Codable, Hashable, Sendable {
    public let modelID: CloudModelIdentifier
    public let limit: Int
    public let cursor: CloudPageCursor?
    public let desiredFields: Set<CloudFieldIdentifier>

    public init(
        modelID: CloudModelIdentifier,
        limit: Int = 100,
        cursor: CloudPageCursor? = nil,
        desiredFields: Set<CloudFieldIdentifier> = []
    ) throws {
        guard limit > 0 else { throw CloudRecordBoundaryError.invalidLimit(limit) }
        self.modelID = modelID
        self.limit = limit
        self.cursor = cursor
        self.desiredFields = desiredFields
    }

    private enum CodingKeys: String, CodingKey {
        case modelID
        case limit
        case cursor
        case desiredFields
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(limit, forKey: .limit)
        try container.encodeIfPresent(cursor, forKey: .cursor)
        try container.encode(
            desiredFields.sorted(),
            forKey: .desiredFields
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            modelID: container.decode(CloudModelIdentifier.self, forKey: .modelID),
            limit: container.decode(Int.self, forKey: .limit),
            cursor: container.decodeIfPresent(CloudPageCursor.self, forKey: .cursor),
            desiredFields: Set(container.decode([CloudFieldIdentifier].self, forKey: .desiredFields))
        )
    }
}

/// A page of immutable records and an optional continuation token.
public struct CloudRecordPage: Codable, Hashable, Sendable {
    public let snapshots: [CloudRecordSnapshot]
    public let nextCursor: CloudPageCursor?
    public let failures: [CloudRecordFailure]

    public init(
        snapshots: [CloudRecordSnapshot],
        nextCursor: CloudPageCursor? = nil,
        failures: [CloudRecordFailure] = []
    ) throws {
        var seen = Set<CloudRecordIdentifier>()
        for snapshot in snapshots {
            guard seen.insert(snapshot.id).inserted else {
                throw CloudRecordBoundaryError.duplicateRecordIdentifier(snapshot.id)
            }
        }
        for failure in failures {
            guard seen.insert(failure.id).inserted else {
                throw CloudRecordBoundaryError.duplicateRecordIdentifier(failure.id)
            }
        }
        self.snapshots = snapshots
        self.nextCursor = nextCursor
        self.failures = failures
    }

    private enum CodingKeys: String, CodingKey {
        case snapshots
        case nextCursor
        case failures
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            snapshots: container.decode([CloudRecordSnapshot].self, forKey: .snapshots),
            nextCursor: container.decodeIfPresent(CloudPageCursor.self, forKey: .nextCursor),
            failures: container.decode([CloudRecordFailure].self, forKey: .failures)
        )
    }
}

public enum CloudRecordOperation: String, Codable, Hashable, Sendable {
    case fetch
    case save
    case delete
}

/// A per-record failure in a non-atomic modification result.
public struct CloudRecordFailure: Codable, Hashable, Sendable {
    public let id: CloudRecordIdentifier
    public let operation: CloudRecordOperation
    public let error: CloudModelError
    public let conflict: CloudRecordConflict?

    public init(
        id: CloudRecordIdentifier,
        operation: CloudRecordOperation,
        error: CloudModelError,
        conflict: CloudRecordConflict? = nil
    ) {
        self.id = id
        self.operation = operation
        self.error = error
        self.conflict = conflict
    }
}

/// The explicit outcome of a non-atomic or partially successful modification.
public struct CloudModifyResult: Codable, Hashable, Sendable {
    public let saved: [CloudRecordSnapshot]
    public let deleted: [CloudRecordIdentifier]
    public let failures: [CloudRecordFailure]

    public init(
        saved: [CloudRecordSnapshot] = [],
        deleted: [CloudRecordIdentifier] = [],
        failures: [CloudRecordFailure] = []
    ) throws {
        var seen = Set<CloudRecordIdentifier>()
        for snapshot in saved {
            guard seen.insert(snapshot.id).inserted else {
                throw CloudRecordBoundaryError.duplicateRecordIdentifier(snapshot.id)
            }
        }
        for id in deleted {
            guard seen.insert(id).inserted else {
                throw CloudRecordBoundaryError.duplicateRecordIdentifier(id)
            }
        }
        for failure in failures {
            guard seen.insert(failure.id).inserted else {
                throw CloudRecordBoundaryError.duplicateRecordIdentifier(failure.id)
            }
        }
        self.saved = saved
        self.deleted = deleted
        self.failures = failures
    }

    private enum CodingKeys: String, CodingKey {
        case saved
        case deleted
        case failures
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            saved: container.decode([CloudRecordSnapshot].self, forKey: .saved),
            deleted: container.decode([CloudRecordIdentifier].self, forKey: .deleted),
            failures: container.decode([CloudRecordFailure].self, forKey: .failures)
        )
    }

    public var isPartial: Bool { failures.isEmpty == false }
}

/// The persistence boundary used by the local context and CloudKit-backed store.
public protocol CloudDatabaseClient: Sendable {
    func fetch(_ request: CloudRecordFetchRequest) async throws -> CloudRecordPage

    func modify(
        saving mutations: [CloudRecordMutation],
        deleting recordIDs: [CloudRecordIdentifier],
        atomic: Bool
    ) async throws -> CloudModifyResult
}
