import Foundation

/// Errors raised while constructing the typed record boundary.
public enum CloudRecordBoundaryError: Error, Equatable, Sendable {
    case emptyCursor
    case emptyChangeTag
    case invalidLimit(Int)
    case duplicateRecordIdentifier(CloudRecordIdentifier)
    case duplicateFieldIdentifier(CloudFieldIdentifier)
    case fieldIsBothSetAndRemoved(CloudFieldIdentifier)
}

/// Errors returned by a record store after a request has been accepted.
public enum CloudModelError: Error, Codable, Equatable, Hashable, Sendable {
    case invalidRequest(String)
    case notFound(CloudRecordIdentifier)
    case conflict(
        CloudRecordIdentifier,
        expectedChangeTag: String?,
        actualChangeTag: String?
    )
    case partialFailure
    case unsupported(String)
    case retryable(String, retryAfter: TimeInterval?)
    case cancelled
}

/// A value that can cross the model/runtime and database boundary without `Any`.
///
/// Optional values are represented by omitting a field from a snapshot or mutation.
/// Asset values carry remote-safe metadata; temporary upload paths stay outside this
/// boundary in `CloudAssetUpload`.
public enum CloudRecordValue: Codable, Hashable, Sendable {
    case string(String)
    case int64(Int64)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case reference(CloudRecordIdentifier)
    case asset(CloudAssetReference)
    case stringArray([String])
    case int64Array([Int64])
    case doubleArray([Double])
    case dateArray([Date])
    case referenceArray([CloudRecordIdentifier])

    public var kind: CloudRecordValueKind {
        switch self {
        case .string: .string
        case .int64: .int64
        case .double: .double
        case .bool: .bool
        case .date: .date
        case .data: .data
        case .reference: .reference
        case .asset: .asset
        case .stringArray: .stringArray
        case .int64Array: .int64Array
        case .doubleArray: .doubleArray
        case .dateArray: .dateArray
        case .referenceArray: .referenceArray
        }
    }
}

public enum CloudRecordValueKind: String, Codable, Hashable, Sendable {
    case string
    case int64
    case double
    case bool
    case date
    case data
    case reference
    case asset
    case stringArray
    case int64Array
    case doubleArray
    case dateArray
    case referenceArray
}

public enum CloudValueCodecError: Error, Codable, Equatable, Hashable, Sendable {
    case expectedData(actual: CloudRecordValueKind)
    case encodingFailed(String)
    case decodingFailed(String)
}

public protocol CloudRecordValueCodec: Sendable {
    associatedtype Value: Codable & Sendable

    func encode(_ value: Value) throws -> CloudRecordValue
    func decode(_ value: CloudRecordValue) throws -> Value
}

/// A deterministic codec for custom Codable values stored as JSON bytes.
public struct CloudJSONRecordValueCodec<Value: Codable & Sendable>: CloudRecordValueCodec {
    public init() {}

    public func encode(_ value: Value) throws -> CloudRecordValue {
        do {
            return try .data(JSONEncoder().encode(value))
        } catch {
            throw CloudValueCodecError.encodingFailed(String(describing: error))
        }
    }

    public func decode(_ value: CloudRecordValue) throws -> Value {
        guard case let .data(data) = value else {
            throw CloudValueCodecError.expectedData(actual: value.kind)
        }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw CloudValueCodecError.decodingFailed(String(describing: error))
        }
    }
}

/// An opaque, validated continuation token for a fetch page.
public struct CloudPageCursor: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else { throw CloudRecordBoundaryError.emptyCursor }
        self.rawValue = value
    }

    private enum CodingKeys: String, CodingKey { case rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(String.self, forKey: .rawValue))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }

    public var description: String { rawValue }
}

/// The write behavior requested for a record mutation.
public enum CloudRecordWritePolicy: Codable, Hashable, Sendable {
    case insert
    case update(expectedChangeTag: String)
    case upsert

    public init(updateExpectedChangeTag rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else { throw CloudRecordBoundaryError.emptyChangeTag }
        self = .update(expectedChangeTag: value)
    }
}

/// An immutable record returned by a store.
public struct CloudRecordSnapshot: Codable, Hashable, Sendable {
    public let id: CloudRecordIdentifier
    public let modelID: CloudModelIdentifier
    public let changeTag: String?
    public let fields: [CloudFieldIdentifier: CloudRecordValue]
    /// `true` when the snapshot was projected with a desired-field set and
    /// therefore cannot be used to infer that omitted fields were deleted.
    public let isPartial: Bool

    public init(
        id: CloudRecordIdentifier,
        modelID: CloudModelIdentifier,
        changeTag: String? = nil,
        fields: [CloudFieldIdentifier: CloudRecordValue] = [:],
        isPartial: Bool = false
    ) throws {
        if let changeTag {
            let value = changeTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.isEmpty == false else { throw CloudRecordBoundaryError.emptyChangeTag }
            self.changeTag = value
        } else {
            self.changeTag = nil
        }
        self.id = id
        self.modelID = modelID
        self.fields = fields
        self.isPartial = isPartial
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case modelID
        case changeTag
        case fields
        case isPartial
    }

    private struct FieldEntry: Codable {
        let key: CloudFieldIdentifier
        let value: CloudRecordValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(modelID, forKey: .modelID)
        try container.encodeIfPresent(changeTag, forKey: .changeTag)
        try container.encode(isPartial, forKey: .isPartial)
        let entries = fields
            .sorted { $0.key < $1.key }
            .map { FieldEntry(key: $0.key, value: $0.value) }
        try container.encode(entries, forKey: .fields)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(CloudRecordIdentifier.self, forKey: .id)
        let modelID = try container.decode(CloudModelIdentifier.self, forKey: .modelID)
        let changeTag = try container.decodeIfPresent(String.self, forKey: .changeTag)
        let entries = try container.decode([FieldEntry].self, forKey: .fields)
        let isPartial = try container.decodeIfPresent(Bool.self, forKey: .isPartial) ?? false
        var fields = [CloudFieldIdentifier: CloudRecordValue](minimumCapacity: entries.count)
        for entry in entries {
            guard fields.updateValue(entry.value, forKey: entry.key) == nil else {
                throw CloudRecordBoundaryError.duplicateFieldIdentifier(entry.key)
            }
        }
        try self.init(
            id: id,
            modelID: modelID,
            changeTag: changeTag,
            fields: fields,
            isPartial: isPartial
        )
    }
}
