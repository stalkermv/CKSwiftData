import Foundation

public struct CloudRelationshipEdgeQuery: Codable, Hashable, Sendable {
    public let source: CloudRecordIdentifier
    public let relationship: CloudFieldIdentifier
    public let limit: Int
    public let cursor: CloudPageCursor?

    public init(
        source: CloudRecordIdentifier,
        relationship: CloudFieldIdentifier,
        limit: Int = 100,
        cursor: CloudPageCursor? = nil
    ) throws {
        guard limit > 0 else {
            throw CloudRecordBoundaryError.invalidLimit(limit)
        }
        self.source = source
        self.relationship = relationship
        self.limit = limit
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case relationship
        case limit
        case cursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            source: container.decode(CloudRecordIdentifier.self, forKey: .source),
            relationship: container.decode(CloudFieldIdentifier.self, forKey: .relationship),
            limit: container.decode(Int.self, forKey: .limit),
            cursor: container.decodeIfPresent(CloudPageCursor.self, forKey: .cursor)
        )
    }
}

public struct CloudRelationshipEdgePage: Codable, Hashable, Sendable {
    public let edges: [CloudRelationshipEdge]
    public let nextCursor: CloudPageCursor?

    public init(
        edges: [CloudRelationshipEdge],
        nextCursor: CloudPageCursor? = nil
    ) {
        self.edges = edges
        self.nextCursor = nextCursor
    }
}

private struct CloudRelationshipEdgeCursorEnvelope: Codable, Sendable {
    let source: CloudRecordIdentifier
    let relationship: CloudFieldIdentifier
    let storeCursor: CloudPageCursor
}

/// Reads canonical edge records without materializing an unbounded array on the
/// owner record. The injected store remains responsible for paging and retries.
public struct CloudRelationshipEdgeReader: Sendable {
    private static let cursorPrefix = "edge-v1:"

    public let store: CloudKitRecordStore
    public let edgeModelID: CloudModelIdentifier
    public let sourceField: CloudFieldIdentifier
    public let relationshipField: CloudFieldIdentifier
    public let targetField: CloudFieldIdentifier
    public let positionField: CloudFieldIdentifier?

    public init(
        store: CloudKitRecordStore,
        edgeModelID: CloudModelIdentifier,
        sourceField: CloudFieldIdentifier,
        relationshipField: CloudFieldIdentifier,
        targetField: CloudFieldIdentifier,
        positionField: CloudFieldIdentifier? = nil
    ) {
        self.store = store
        self.edgeModelID = edgeModelID
        self.sourceField = sourceField
        self.relationshipField = relationshipField
        self.targetField = targetField
        self.positionField = positionField
    }

    public func fetch(
        _ query: CloudRelationshipEdgeQuery,
        retryPolicy: CloudRetryPolicy = .none
    ) async throws -> CloudRelationshipEdgePage {
        var cursor = try query.cursor.map {
            try Self.storeCursor(from: $0, for: query)
        }
        var collected = [CloudRelationshipEdge]()
        var rawNextCursor: CloudPageCursor?

        while true {
            // Filtering canonical edge records happens client-side. A remote
            // page can therefore contain more matching edges than the number
            // still needed for this response; using a one-record page keeps
            // the store cursor immediately after the last returned edge and
            // prevents unmatched tail records from being skipped.
            let request = try CloudRecordFetchRequest(
                modelID: edgeModelID,
                limit: 1,
                cursor: cursor,
                desiredFields: Set([
                    sourceField,
                    relationshipField,
                    targetField,
                    positionField
                ].compactMap(\.self))
            )
            let page = try await store.fetch(request, retryPolicy: retryPolicy)
            for snapshot in page.snapshots {
                guard snapshot.fields[sourceField] == .reference(query.source),
                      snapshot.fields[relationshipField] == .string(query.relationship.rawValue),
                      case let .reference(target)? = snapshot.fields[targetField]
                else {
                    continue
                }
                let position: Int64? = if let positionField,
                                          case let .int64(value)? = snapshot.fields[positionField]
                {
                    value
                } else {
                    nil
                }
                try collected.append(CloudRelationshipEdge(
                    source: query.source,
                    relationship: query.relationship,
                    target: target,
                    position: position
                ))
            }
            guard collected.count < query.limit, let pageCursor = page.nextCursor else {
                rawNextCursor = collected.count >= query.limit ? page.nextCursor : nil
                break
            }
            cursor = pageCursor
        }

        collected.sort {
            switch ($0.position, $1.position) {
            case let (lhs?, rhs?):
                if lhs != rhs { return lhs < rhs }
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
            return $0.target.recordName < $1.target.recordName
        }
        if collected.count > query.limit {
            collected = Array(collected.prefix(query.limit))
        }
        let nextCursor = try rawNextCursor.map {
            try Self.edgeCursor(for: query, storeCursor: $0)
        }
        return CloudRelationshipEdgePage(edges: collected, nextCursor: nextCursor)
    }

    private static func edgeCursor(
        for query: CloudRelationshipEdgeQuery,
        storeCursor: CloudPageCursor
    ) throws -> CloudPageCursor {
        let envelope = CloudRelationshipEdgeCursorEnvelope(
            source: query.source,
            relationship: query.relationship,
            storeCursor: storeCursor
        )
        let data = try JSONEncoder().encode(envelope)
        return try CloudPageCursor(cursorPrefix + data.base64EncodedString())
    }

    private static func storeCursor(
        from cursor: CloudPageCursor,
        for query: CloudRelationshipEdgeQuery
    ) throws -> CloudPageCursor {
        guard cursor.rawValue.hasPrefix(cursorPrefix) else {
            throw CloudModelError.invalidRequest("invalid relationship edge cursor")
        }
        let encoded = String(cursor.rawValue.dropFirst(cursorPrefix.count))
        guard let data = Data(base64Encoded: encoded),
              let envelope = try? JSONDecoder().decode(
                  CloudRelationshipEdgeCursorEnvelope.self,
                  from: data
              )
        else {
            throw CloudModelError.invalidRequest("invalid relationship edge cursor")
        }
        guard envelope.source == query.source,
              envelope.relationship == query.relationship
        else {
            throw CloudModelError.invalidRequest(
                "relationship edge cursor scope does not match query"
            )
        }
        return envelope.storeCursor
    }
}
