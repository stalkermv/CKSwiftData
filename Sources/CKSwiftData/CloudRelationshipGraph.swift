import Foundation

public enum CloudRelationshipGraphError: Error, Codable, Equatable, Hashable, Sendable {
    case crossZone(CloudRecordIdentifier, CloudRecordIdentifier)
    case duplicateTarget(CloudRecordIdentifier)
    case invalidPosition(Int64)
    case invalidEdgeModel(CloudModelIdentifier)
    case denyDelete(CloudRecordIdentifier, CloudFieldIdentifier)
    case duplicateOperation(CloudRecordIdentifier)
    case operationOverlap(CloudRecordIdentifier)
}

/// One canonical edge in a to-many relationship graph.
public struct CloudRelationshipEdge: Codable, Hashable, Sendable {
    public let source: CloudRecordIdentifier
    public let relationship: CloudFieldIdentifier
    public let target: CloudRecordIdentifier
    public let position: Int64?

    public init(
        source: CloudRecordIdentifier,
        relationship: CloudFieldIdentifier,
        target: CloudRecordIdentifier,
        position: Int64? = nil
    ) throws {
        guard source.zone == target.zone else {
            throw CloudRelationshipGraphError.crossZone(source, target)
        }
        if let position, position < 0 {
            throw CloudRelationshipGraphError.invalidPosition(position)
        }
        self.source = source
        self.relationship = relationship
        self.target = target
        self.position = position
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case relationship
        case target
        case position
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            source: container.decode(CloudRecordIdentifier.self, forKey: .source),
            relationship: container.decode(CloudFieldIdentifier.self, forKey: .relationship),
            target: container.decode(CloudRecordIdentifier.self, forKey: .target),
            position: container.decodeIfPresent(Int64.self, forKey: .position)
        )
    }

    public func recordID(in zone: CloudZoneIdentifier) throws -> CloudRecordIdentifier {
        let raw = Self.edgeRecordName(source: source, relationship: relationship, target: target)
        return try CloudRecordIdentifier(recordName: raw, zone: zone)
    }

    public func recordID(edgeModelID: CloudModelIdentifier) throws -> CloudRecordIdentifier {
        try CloudRecordIdentifier(
            recordName: Self.edgeRecordName(
                source: source,
                relationship: relationship,
                target: target,
                edgeModelID: edgeModelID
            ),
            zone: source.zone
        )
    }

    private static func edgeRecordName(
        source: CloudRecordIdentifier,
        relationship: CloudFieldIdentifier,
        target: CloudRecordIdentifier,
        edgeModelID: CloudModelIdentifier? = nil
    ) -> String {
        let modelPart = edgeModelID.map { "\($0.rawValue)|" } ?? ""
        let canonical = "\(modelPart)\(source.zone.rawValue)|\(source.recordName)|\(relationship.rawValue)|\(target.zone.rawValue)|\(target.recordName)"
        var first: UInt64 = 14_695_981_039_346_656_037
        var second: UInt64 = 10_951_624_211_601_645_003
        for byte in canonical.utf8 {
            first ^= UInt64(byte)
            first &*= 1_099_511_628_211
            second ^= UInt64(byte)
            second &*= 1_099_511_628_211
            second = second.rotateLeft(by: 7)
        }
        return String(format: "edge-%016llx%016llx", first, second)
    }
}

private extension UInt64 {
    func rotateLeft(by amount: UInt64) -> UInt64 {
        (self << amount) | (self >> (64 - amount))
    }
}

public struct CloudRelationshipChange: Codable, Hashable, Sendable {
    public let source: CloudRecordIdentifier
    public let relationship: CloudFieldIdentifier
    public let oldTargets: [CloudRecordIdentifier]
    public let newTargets: [CloudRecordIdentifier]
    public let ordering: CloudRelationshipOrdering

    public init(
        source: CloudRecordIdentifier,
        relationship: CloudFieldIdentifier,
        oldTargets: [CloudRecordIdentifier],
        newTargets: [CloudRecordIdentifier],
        ordering: CloudRelationshipOrdering = .unordered
    ) throws {
        try Self.validateTargets(source: source, targets: oldTargets)
        try Self.validateTargets(source: source, targets: newTargets)
        self.source = source
        self.relationship = relationship
        self.oldTargets = oldTargets
        self.newTargets = newTargets
        self.ordering = ordering
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case relationship
        case oldTargets
        case newTargets
        case ordering
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            source: container.decode(CloudRecordIdentifier.self, forKey: .source),
            relationship: container.decode(CloudFieldIdentifier.self, forKey: .relationship),
            oldTargets: container.decode([CloudRecordIdentifier].self, forKey: .oldTargets),
            newTargets: container.decode([CloudRecordIdentifier].self, forKey: .newTargets),
            ordering: container.decode(CloudRelationshipOrdering.self, forKey: .ordering)
        )
    }

    private static func validateTargets(
        source: CloudRecordIdentifier,
        targets: [CloudRecordIdentifier]
    ) throws {
        var seen = Set<CloudRecordIdentifier>()
        for target in targets {
            guard source.zone == target.zone else {
                throw CloudRelationshipGraphError.crossZone(source, target)
            }
            guard seen.insert(target).inserted else {
                throw CloudRelationshipGraphError.duplicateTarget(target)
            }
        }
    }
}

public struct CloudRelationshipPersistencePlan: Codable, Hashable, Sendable {
    public let saving: [CloudRecordMutation]
    public let deletingEdges: [CloudRecordIdentifier]
    public let deletingRecords: [CloudRecordIdentifier]

    public init(
        saving: [CloudRecordMutation] = [],
        deletingEdges: [CloudRecordIdentifier] = [],
        deletingRecords: [CloudRecordIdentifier] = []
    ) throws {
        var saves = Set<CloudRecordIdentifier>()
        for mutation in saving {
            guard saves.insert(mutation.id).inserted else {
                throw CloudRelationshipGraphError.duplicateOperation(mutation.id)
            }
        }
        var edgeDeletes = Set<CloudRecordIdentifier>()
        for id in deletingEdges {
            guard edgeDeletes.insert(id).inserted else {
                throw CloudRelationshipGraphError.duplicateOperation(id)
            }
            guard saves.contains(id) == false else {
                throw CloudRelationshipGraphError.operationOverlap(id)
            }
        }
        var recordDeletes = Set<CloudRecordIdentifier>()
        for id in deletingRecords {
            guard recordDeletes.insert(id).inserted else {
                throw CloudRelationshipGraphError.duplicateOperation(id)
            }
            guard saves.contains(id) == false,
                  edgeDeletes.contains(id) == false
            else {
                throw CloudRelationshipGraphError.operationOverlap(id)
            }
        }
        self.saving = saving
        self.deletingEdges = deletingEdges
        self.deletingRecords = deletingRecords
    }

    private enum CodingKeys: String, CodingKey {
        case saving
        case deletingEdges
        case deletingRecords
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            saving: container.decode([CloudRecordMutation].self, forKey: .saving),
            deletingEdges: container.decode([CloudRecordIdentifier].self, forKey: .deletingEdges),
            deletingRecords: container.decode([CloudRecordIdentifier].self, forKey: .deletingRecords)
        )
    }

    public var isEmpty: Bool {
        saving.isEmpty && deletingEdges.isEmpty && deletingRecords.isEmpty
    }
}

/// Computes cycle-safe edge mutations from old/new relationship collections.
public struct CloudRelationshipGraphPlanner: Sendable {
    public let edgeModelID: CloudModelIdentifier
    public let sourceField: CloudFieldIdentifier
    public let relationshipField: CloudFieldIdentifier
    public let targetField: CloudFieldIdentifier
    public let positionField: CloudFieldIdentifier?

    public init(
        edgeModelID: CloudModelIdentifier,
        sourceField: CloudFieldIdentifier,
        relationshipField: CloudFieldIdentifier,
        targetField: CloudFieldIdentifier,
        positionField: CloudFieldIdentifier? = nil
    ) {
        self.edgeModelID = edgeModelID
        self.sourceField = sourceField
        self.relationshipField = relationshipField
        self.targetField = targetField
        self.positionField = positionField
    }

    public func plan(_ change: CloudRelationshipChange) throws -> CloudRelationshipPersistencePlan {
        try plan([change])
    }

    public func plan(
        _ changes: [CloudRelationshipChange]
    ) throws -> CloudRelationshipPersistencePlan {
        var saves = [CloudRecordMutation]()
        var deletes = [CloudRecordIdentifier]()
        for change in changes {
            let new = Set(change.newTargets)
            for (index, target) in change.newTargets.enumerated() {
                let edge = try CloudRelationshipEdge(
                    source: change.source,
                    relationship: change.relationship,
                    target: target,
                    position: change.ordering == .stable ? Int64(index) : nil
                )
                let id = try edge.recordID(edgeModelID: edgeModelID)
                var values: [CloudFieldIdentifier: CloudRecordValue] = [
                    sourceField: .reference(change.source),
                    relationshipField: .string(change.relationship.rawValue),
                    targetField: .reference(target)
                ]
                if let positionField, let position = edge.position {
                    values[positionField] = .int64(position)
                }
                try saves.append(CloudRecordMutation(
                    id: id,
                    modelID: edgeModelID,
                    values: values,
                    policy: .upsert
                ))
            }
            for target in change.oldTargets where new.contains(target) == false {
                let edge = try CloudRelationshipEdge(
                    source: change.source,
                    relationship: change.relationship,
                    target: target
                )
                try deletes.append(edge.recordID(edgeModelID: edgeModelID))
            }
        }
        saves.sort { $0.id.recordName < $1.id.recordName }
        deletes.sort { $0.recordName < $1.recordName }
        return try CloudRelationshipPersistencePlan(
            saving: saves,
            deletingEdges: deletes
        )
    }

    public func planDelete(
        source: CloudRecordIdentifier,
        relationship: CloudFieldIdentifier,
        targets: [CloudRecordIdentifier],
        deleteRule: CloudDeleteRule
    ) throws -> CloudRelationshipPersistencePlan {
        let change = try CloudRelationshipChange(
            source: source,
            relationship: relationship,
            oldTargets: targets,
            newTargets: []
        )
        let edgePlan = try plan(change)
        switch deleteRule {
        case .noAction, .nullify:
            return edgePlan
        case .cascade:
            return try CloudRelationshipPersistencePlan(
                saving: edgePlan.saving,
                deletingEdges: edgePlan.deletingEdges,
                deletingRecords: targets
            )
        case .deny:
            guard targets.isEmpty else {
                throw CloudRelationshipGraphError.denyDelete(source, relationship)
            }
            return edgePlan
        }
    }
}

public extension CloudKitRecordStore {
    func apply(
        _ plan: CloudRelationshipPersistencePlan,
        atomic: Bool = true,
        retryPolicy: CloudRetryPolicy = .none
    ) async throws -> CloudModifyResult {
        try await modify(
            saving: plan.saving,
            deleting: plan.deletingEdges + plan.deletingRecords,
            atomic: atomic,
            retryPolicy: retryPolicy
        )
    }
}
