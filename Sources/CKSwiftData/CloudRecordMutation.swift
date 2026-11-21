import Foundation

/// A record mutation. Fields in `values` are written and fields in
/// `removedFields` are cleared; fields omitted from both collections are
/// unchanged. `insert` and `upsert` must include every required schema field;
/// use `update` for a partial write to an existing record.
public struct CloudRecordMutation: Codable, Hashable, Sendable {
    public let id: CloudRecordIdentifier
    public let modelID: CloudModelIdentifier
    public let values: [CloudFieldIdentifier: CloudRecordValue]
    public let removedFields: Set<CloudFieldIdentifier>
    public let policy: CloudRecordWritePolicy

    public init(
        id: CloudRecordIdentifier,
        modelID: CloudModelIdentifier,
        values: [CloudFieldIdentifier: CloudRecordValue] = [:],
        removedFields: Set<CloudFieldIdentifier> = [],
        policy: CloudRecordWritePolicy = .upsert
    ) throws {
        let normalizedPolicy: CloudRecordWritePolicy
        switch policy {
        case .insert, .upsert:
            normalizedPolicy = policy
        case let .update(expectedChangeTag):
            let value = expectedChangeTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.isEmpty == false else {
                throw CloudRecordBoundaryError.emptyChangeTag
            }
            normalizedPolicy = .update(expectedChangeTag: value)
        }

        let overlap = values.keys.first { removedFields.contains($0) }
        guard let overlap else {
            self.id = id
            self.modelID = modelID
            self.values = values
            self.removedFields = removedFields
            self.policy = normalizedPolicy
            return
        }
        throw CloudRecordBoundaryError.fieldIsBothSetAndRemoved(overlap)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case modelID
        case values
        case removedFields
        case policy
    }

    private struct FieldEntry: Codable {
        let key: CloudFieldIdentifier
        let value: CloudRecordValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(modelID, forKey: .modelID)
        let entries = values
            .sorted { $0.key < $1.key }
            .map { FieldEntry(key: $0.key, value: $0.value) }
        try container.encode(entries, forKey: .values)
        try container.encode(
            removedFields.sorted(),
            forKey: .removedFields
        )
        try container.encode(policy, forKey: .policy)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(CloudRecordIdentifier.self, forKey: .id)
        let modelID = try container.decode(CloudModelIdentifier.self, forKey: .modelID)
        let entries = try container.decode([FieldEntry].self, forKey: .values)
        let removedFields = try container.decode(
            [CloudFieldIdentifier].self,
            forKey: .removedFields
        )
        let policy = try container.decode(CloudRecordWritePolicy.self, forKey: .policy)

        var values = [CloudFieldIdentifier: CloudRecordValue](minimumCapacity: entries.count)
        for entry in entries {
            guard values.updateValue(entry.value, forKey: entry.key) == nil else {
                throw CloudRecordBoundaryError.duplicateFieldIdentifier(entry.key)
            }
        }
        var removed = Set<CloudFieldIdentifier>()
        for field in removedFields {
            guard removed.insert(field).inserted else {
                throw CloudRecordBoundaryError.duplicateFieldIdentifier(field)
            }
        }
        try self.init(
            id: id,
            modelID: modelID,
            values: values,
            removedFields: removed,
            policy: policy
        )
    }
}
