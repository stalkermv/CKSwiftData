import Foundation

extension CloudModelSchema {
    func validate(mutation: CloudRecordMutation) throws {
        let fieldsByID = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) })

        for (fieldID, value) in mutation.values {
            guard let field = fieldsByID[fieldID] else {
                throw CloudModelError.invalidRequest(
                    "field \(fieldID.rawValue) is not in model \(id.rawValue)"
                )
            }
            try validate(value: value, for: field)
        }

        for fieldID in mutation.removedFields {
            guard let field = fieldsByID[fieldID] else {
                throw CloudModelError.invalidRequest(
                    "field \(fieldID.rawValue) is not in model \(id.rawValue)"
                )
            }
            guard field.isRequired == false else {
                throw CloudModelError.invalidRequest(
                    "required field \(fieldID.rawValue) cannot be removed"
                )
            }
        }

        switch mutation.policy {
        case .insert, .upsert:
            for field in fields where field.isRequired {
                guard mutation.values[field.id] != nil else {
                    throw CloudModelError.invalidRequest(
                        "required field \(field.id.rawValue) is missing for \(mutation.policy == .insert ? "insert" : "upsert")"
                    )
                }
            }
        case .update:
            break
        }
    }

    private func validate(value: CloudRecordValue, for field: CloudFieldSchema) throws {
        switch field {
        case let .attribute(attribute):
            let valid: Bool = switch attribute.kind {
            case .scalar:
                // The manifest deliberately keeps legacy scalar element types
                // opaque. Edge models therefore use scalar fields to carry
                // references until a dedicated edge schema is supplied.
                value.kind != .asset
            case .encoded:
                value.kind == .data
            case .asset:
                value.kind == .asset
            }
            guard valid else {
                throw CloudModelError.invalidRequest(
                    "value kind \(value.kind.rawValue) does not match attribute \(attribute.id.rawValue)"
                )
            }
        case let .relationship(relationship):
            switch relationship.cardinality {
            case .toOne:
                guard value.kind == .reference else {
                    throw CloudModelError.invalidRequest(
                        "relationship \(relationship.id.rawValue) requires a reference"
                    )
                }
            case let .toMany(minimum, maximum, _):
                guard case let .referenceArray(references) = value else {
                    throw CloudModelError.invalidRequest(
                        "relationship \(relationship.id.rawValue) requires a reference array"
                    )
                }
                guard references.count >= minimum,
                      maximum.map({ references.count <= $0 }) ?? true
                else {
                    throw CloudModelError.invalidRequest(
                        "relationship \(relationship.id.rawValue) violates cardinality"
                    )
                }
            }
        }
    }
}

extension CloudFieldSchema {
    var isRequired: Bool {
        switch self {
        case let .attribute(attribute):
            attribute.optionality == .required
        case let .relationship(relationship):
            relationship.cardinality.isRequired
        }
    }
}
