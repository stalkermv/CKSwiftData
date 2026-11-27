import Foundation

public enum CloudSchemaError: Error, Equatable, Sendable {
    case invalidMinimum(Int)
    case invalidBounds(minimum: Int, maximum: Int)
    case invalidAttributeOption(id: CloudFieldIdentifier, reason: String)
    case invalidSchemaVersion(Int)
    case duplicateModelIdentifier(CloudModelIdentifier)
    case duplicateRecordType(CloudModelIdentifier)
    case duplicateFieldIdentifier(CloudModelIdentifier, CloudFieldIdentifier)
    case duplicateRecordFieldName(CloudModelIdentifier, CloudFieldIdentifier)
    case unknownRelationshipDestination(CloudModelIdentifier, CloudFieldIdentifier, CloudModelIdentifier)
    case unknownInverse(CloudModelIdentifier, CloudFieldIdentifier, CloudFieldIdentifier)
    case inverseMismatch(CloudModelIdentifier, CloudFieldIdentifier, CloudModelIdentifier)
    case ambiguousInverse(CloudModelIdentifier, CloudFieldIdentifier)
}

public enum CloudAttributeKind: String, Codable, Hashable, Sendable {
    case scalar
    case encoded
    case asset
}

public enum CloudFieldOptionality: String, Codable, Hashable, Sendable {
    case required
    case optional
}

public enum CloudRelationshipOrdering: String, Codable, Hashable, Sendable {
    case unordered
    case stable
}

public enum CloudRelationshipCardinality: Codable, Hashable, Sendable {
    case toOne(required: Bool)
    case toMany(minimum: Int, maximum: Int?, ordering: CloudRelationshipOrdering)

    public init(
        toManyMinimum minimum: Int = 0,
        maximum: Int? = nil,
        ordering: CloudRelationshipOrdering = .unordered
    ) throws {
        guard minimum >= 0 else { throw CloudSchemaError.invalidMinimum(minimum) }
        if let maximum, maximum < minimum {
            throw CloudSchemaError.invalidBounds(minimum: minimum, maximum: maximum)
        }
        self = .toMany(minimum: minimum, maximum: maximum, ordering: ordering)
    }

    private enum CodingKeys: String, CodingKey {
        case toOne
        case toMany
    }

    private enum ToOneKeys: String, CodingKey {
        case required
    }

    private enum ToManyKeys: String, CodingKey {
        case minimum
        case maximum
        case ordering
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.toOne) {
            let payload = try container.nestedContainer(keyedBy: ToOneKeys.self, forKey: .toOne)
            self = try .toOne(required: payload.decode(Bool.self, forKey: .required))
            return
        }
        let payload = try container.nestedContainer(keyedBy: ToManyKeys.self, forKey: .toMany)
        try self.init(
            toManyMinimum: payload.decode(Int.self, forKey: .minimum),
            maximum: payload.decodeIfPresent(Int.self, forKey: .maximum),
            ordering: payload.decode(CloudRelationshipOrdering.self, forKey: .ordering)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .toOne(required):
            var payload = container.nestedContainer(keyedBy: ToOneKeys.self, forKey: .toOne)
            try payload.encode(required, forKey: .required)
        case let .toMany(minimum, maximum, ordering):
            var payload = container.nestedContainer(keyedBy: ToManyKeys.self, forKey: .toMany)
            try payload.encode(minimum, forKey: .minimum)
            try payload.encodeIfPresent(maximum, forKey: .maximum)
            try payload.encode(ordering, forKey: .ordering)
        }
    }

    public var isToMany: Bool {
        if case .toMany = self { true } else { false }
    }

    public var isRequired: Bool {
        switch self {
        case let .toOne(required): required
        case let .toMany(minimum, _, _): minimum > 0
        }
    }
}

public enum CloudDeleteRule: String, Codable, Hashable, Sendable {
    case noAction
    case nullify
    case cascade
    case deny
}

public struct CloudAttributeSchema: Codable, Hashable, Sendable {
    public let id: CloudFieldIdentifier
    public let recordName: CloudFieldIdentifier
    public let kind: CloudAttributeKind
    public let optionality: CloudFieldOptionality
    public let renamedFrom: CloudFieldIdentifier?
    public let encrypted: Bool
    public let externalStorage: Bool
    /// The boundary kind of the stored value when it is known. It lets a
    /// decoder recover the element type of an empty array, which CloudKit
    /// returns without any element to infer it from.
    public let valueKind: CloudRecordValueKind?

    public init(
        id: CloudFieldIdentifier,
        recordName: CloudFieldIdentifier,
        kind: CloudAttributeKind,
        optionality: CloudFieldOptionality = .required,
        renamedFrom: CloudFieldIdentifier? = nil,
        encrypted: Bool = false,
        externalStorage: Bool = false,
        valueKind: CloudRecordValueKind? = nil
    ) throws {
        if kind == .asset, encrypted {
            throw CloudSchemaError.invalidAttributeOption(id: id, reason: "assets cannot be encrypted")
        }
        if kind != .asset, externalStorage {
            throw CloudSchemaError.invalidAttributeOption(id: id, reason: "external storage requires an asset field")
        }
        self.id = id
        self.recordName = recordName
        self.kind = kind
        self.optionality = optionality
        self.renamedFrom = renamedFrom
        self.encrypted = encrypted
        self.externalStorage = externalStorage
        self.valueKind = valueKind
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case recordName
        case kind
        case optionality
        case renamedFrom
        case encrypted
        case externalStorage
        case valueKind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(CloudFieldIdentifier.self, forKey: .id),
            recordName: container.decode(CloudFieldIdentifier.self, forKey: .recordName),
            kind: container.decode(CloudAttributeKind.self, forKey: .kind),
            optionality: container.decode(CloudFieldOptionality.self, forKey: .optionality),
            renamedFrom: container.decodeIfPresent(CloudFieldIdentifier.self, forKey: .renamedFrom),
            encrypted: container.decode(Bool.self, forKey: .encrypted),
            externalStorage: container.decode(Bool.self, forKey: .externalStorage),
            valueKind: container.decodeIfPresent(CloudRecordValueKind.self, forKey: .valueKind)
        )
    }
}

public struct CloudRelationshipSchema: Codable, Hashable, Sendable {
    public let id: CloudFieldIdentifier
    public let recordName: CloudFieldIdentifier
    public let destination: CloudModelIdentifier
    public let inverse: CloudFieldIdentifier?
    public let cardinality: CloudRelationshipCardinality
    public let deleteRule: CloudDeleteRule

    public init(
        id: CloudFieldIdentifier,
        recordName: CloudFieldIdentifier,
        destination: CloudModelIdentifier,
        inverse: CloudFieldIdentifier? = nil,
        cardinality: CloudRelationshipCardinality,
        deleteRule: CloudDeleteRule = .nullify
    ) {
        self.id = id
        self.recordName = recordName
        self.destination = destination
        self.inverse = inverse
        self.cardinality = cardinality
        self.deleteRule = deleteRule
    }
}

public enum CloudFieldSchema: Codable, Hashable, Sendable {
    case attribute(CloudAttributeSchema)
    case relationship(CloudRelationshipSchema)

    public var id: CloudFieldIdentifier {
        switch self {
        case let .attribute(value): value.id
        case let .relationship(value): value.id
        }
    }

    public var recordName: CloudFieldIdentifier {
        switch self {
        case let .attribute(value): value.recordName
        case let .relationship(value): value.recordName
        }
    }

    /// The relationship shape is always known. A scalar attribute's value kind
    /// is known when the manifest records it. Together they are enough to
    /// decode empty arrays without relying on bridged `NSArray` runtime casts.
    var expectedCloudRecordValueKind: CloudRecordValueKind? {
        switch self {
        case let .attribute(attribute):
            attribute.valueKind
        case let .relationship(relationship):
            relationship.cardinality.isToMany ? .referenceArray : .reference
        }
    }

    var isEncrypted: Bool {
        if case let .attribute(attribute) = self {
            return attribute.encrypted
        }
        return false
    }
}
