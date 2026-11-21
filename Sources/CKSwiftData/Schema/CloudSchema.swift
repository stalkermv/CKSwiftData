import Foundation

public struct CloudModelSchema: Codable, Hashable, Sendable {
    public let id: CloudModelIdentifier
    public let recordType: CloudModelIdentifier
    public let version: Int
    public let fields: [CloudFieldSchema]

    public init(
        id: CloudModelIdentifier,
        recordType: CloudModelIdentifier,
        version: Int = 1,
        fields: [CloudFieldSchema]
    ) throws {
        guard version > 0 else { throw CloudSchemaError.invalidSchemaVersion(version) }

        var fieldIDs = Set<CloudFieldIdentifier>()
        var recordNames = Set<CloudFieldIdentifier>()
        for field in fields.sorted(by: { $0.id < $1.id }) {
            guard fieldIDs.insert(field.id).inserted else {
                throw CloudSchemaError.duplicateFieldIdentifier(id, field.id)
            }
            guard recordNames.insert(field.recordName).inserted else {
                throw CloudSchemaError.duplicateRecordFieldName(id, field.recordName)
            }
        }

        self.id = id
        self.recordType = recordType
        self.version = version
        self.fields = fields.sorted { $0.id < $1.id }
    }

    public func field(_ id: CloudFieldIdentifier) -> CloudFieldSchema? {
        fields.first { $0.id == id }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(CloudModelIdentifier.self, forKey: .id)
        let recordType = try container.decode(CloudModelIdentifier.self, forKey: .recordType)
        let version = try container.decode(Int.self, forKey: .version)
        let fields = try container.decode([CloudFieldSchema].self, forKey: .fields)
        try self.init(id: id, recordType: recordType, version: version, fields: fields)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case recordType
        case version
        case fields
    }
}

public struct CloudSchema: Codable, Hashable, Sendable {
    public let version: Int
    public let models: [CloudModelSchema]

    public init(version: Int = 1, models: [CloudModelSchema]) throws {
        guard version > 0 else { throw CloudSchemaError.invalidSchemaVersion(version) }

        var modelIDs = Set<CloudModelIdentifier>()
        var recordTypes = Set<CloudModelIdentifier>()
        for model in models.sorted(by: { $0.id < $1.id }) {
            guard modelIDs.insert(model.id).inserted else {
                throw CloudSchemaError.duplicateModelIdentifier(model.id)
            }
            guard recordTypes.insert(model.recordType).inserted else {
                throw CloudSchemaError.duplicateRecordType(model.recordType)
            }
        }

        let orderedModels = models.sorted { $0.id < $1.id }
        let modelsByID = Dictionary(uniqueKeysWithValues: orderedModels.map { ($0.id, $0) })
        try Self.validateRelationships(in: orderedModels, modelsByID: modelsByID)

        self.version = version
        self.models = orderedModels
    }

    public func model(_ id: CloudModelIdentifier) -> CloudModelSchema? {
        models.first { $0.id == id }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        let models = try container.decode([CloudModelSchema].self, forKey: .models)
        try self.init(version: version, models: models)
    }

    private static func validateRelationships(
        in models: [CloudModelSchema],
        modelsByID: [CloudModelIdentifier: CloudModelSchema]
    ) throws {
        for model in models {
            for field in model.fields {
                guard case let .relationship(relationship) = field else { continue }
                guard let destination = modelsByID[relationship.destination] else {
                    throw CloudSchemaError.unknownRelationshipDestination(
                        model.id,
                        relationship.id,
                        relationship.destination
                    )
                }
                guard let inverseID = relationship.inverse else { continue }
                guard let inverseField = destination.field(inverseID) else {
                    throw CloudSchemaError.unknownInverse(model.id, relationship.id, inverseID)
                }
                guard case let .relationship(inverse) = inverseField,
                      inverse.destination == model.id,
                      inverse.inverse == relationship.id
                else {
                    throw CloudSchemaError.inverseMismatch(model.id, relationship.id, destination.id)
                }
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case models
    }
}
