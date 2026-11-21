import CKSwiftData
import Foundation
import Testing

struct CloudSchemaTypesTests {
    @Test
    func cardinalityValidatesBoundsAndExposesShape() throws {
        let cardinality = try CloudRelationshipCardinality(
            toManyMinimum: 1,
            maximum: 3,
            ordering: .stable
        )

        #expect(cardinality.isToMany)
        #expect(cardinality.isRequired)

        do {
            _ = try CloudRelationshipCardinality(toManyMinimum: 4, maximum: 2)
            Issue.record("A maximum below the minimum must be rejected")
        } catch let error as CloudSchemaError {
            #expect(error == .invalidBounds(minimum: 4, maximum: 2))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func attributeOptionsRejectContradictoryStorage() throws {
        let id = try CloudFieldIdentifier("payload")
        let recordName = try CloudFieldIdentifier("payload_data")

        do {
            _ = try CloudAttributeSchema(
                id: id,
                recordName: recordName,
                kind: .scalar,
                externalStorage: true
            )
            Issue.record("External storage must require an asset field")
        } catch let error as CloudSchemaError {
            #expect(error == .invalidAttributeOption(id: id, reason: "external storage requires an asset field"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func decodedSchemaAttributesReapplyStorageInvariants() throws {
        let id = try CloudFieldIdentifier("payload")
        let recordName = try CloudFieldIdentifier("payload")
        let attribute = try CloudAttributeSchema(
            id: id,
            recordName: recordName,
            kind: .asset
        )
        let encoded = try JSONEncoder().encode(attribute)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["encrypted"] = true
        let invalid = try JSONSerialization.data(withJSONObject: object)

        do {
            _ = try JSONDecoder().decode(CloudAttributeSchema.self, from: invalid)
            Issue.record("Decoded asset encryption must be rejected")
        } catch let error as CloudSchemaError {
            #expect(error == .invalidAttributeOption(id: id, reason: "assets cannot be encrypted"))
        }
    }

    @Test
    func fieldSchemaRoundTripsDeterministically() throws {
        let project = try CloudModelIdentifier("Project")
        let fieldID = try CloudFieldIdentifier("tasks")
        let recordName = try CloudFieldIdentifier("task_refs")
        let cardinality = try CloudRelationshipCardinality(ordering: .stable)
        let relationship = CloudRelationshipSchema(
            id: fieldID,
            recordName: recordName,
            destination: project,
            cardinality: cardinality,
            deleteRule: .cascade
        )
        let field = CloudFieldSchema.relationship(relationship)

        let data = try JSONEncoder().encode(field)
        let decoded = try JSONDecoder().decode(CloudFieldSchema.self, from: data)

        #expect(decoded == field)
        #expect(decoded.id == fieldID)
        #expect(decoded.recordName == recordName)
    }
}
