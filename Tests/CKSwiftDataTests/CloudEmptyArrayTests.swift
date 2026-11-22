@testable import CKSwiftData
import CloudKit
import Foundation
import Testing

@CloudModel(recordType: "EmptyArrays")
final class EmptyArrayModel {
    var labels: [String] = []
    var counts: [Int64] = []
    var weights: [Double] = []
    var dates: [Date] = []
    var optionalLabels: [String]?
}

struct CloudEmptyArrayTests {
    @Test
    func emptyScalarArraysSurviveTheModelSnapshotRoundTrip() throws {
        let zone = try CloudZoneIdentifier("_defaultZone")
        let model = EmptyArrayModel()
        model.labels = []
        model.counts = []
        model.weights = []
        model.dates = []

        let snapshot = try model.cloudRecordSnapshot(in: zone)

        #expect(try snapshot.fields[CloudFieldIdentifier("labels")] == .stringArray([]))
        #expect(try snapshot.fields[CloudFieldIdentifier("counts")] == .int64Array([]))
        #expect(try snapshot.fields[CloudFieldIdentifier("weights")] == .doubleArray([]))
        #expect(try snapshot.fields[CloudFieldIdentifier("dates")] == .dateArray([]))

        let restored = try EmptyArrayModel.makeCloudModel(from: snapshot, in: zone)
        #expect(restored.labels.isEmpty)
        #expect(restored.counts.isEmpty)
        #expect(restored.weights.isEmpty)
        #expect(restored.dates.isEmpty)
    }

    @Test
    func emptyArraysFromCloudKitUseTheKindDeclaredByTheSchema() throws {
        let schema = try EmptyArrayModel.cloudModelSchema()
        let record = CKRecord(recordType: "EmptyArrays")
        record["labels"] = [String]()
        record["counts"] = [Int64]()
        record["weights"] = [Double]()
        record["dates"] = [Date]()
        record["optionalLabels"] = [String]()

        var decoded = [String: CloudRecordValue]()
        for field in schema.fields {
            let raw = try #require(record[field.recordName.rawValue])
            decoded[field.id.rawValue] = try CloudRecordValue(
                cloudKitValue: raw,
                fieldID: field.id,
                expectedKind: field.expectedCloudRecordValueKind
            )
        }

        #expect(decoded["labels"] == .stringArray([]))
        #expect(decoded["counts"] == .int64Array([]))
        #expect(decoded["weights"] == .doubleArray([]))
        #expect(decoded["dates"] == .dateArray([]))
        #expect(decoded["optionalLabels"] == .stringArray([]))
    }

    @Test
    func schemaRecordsTheArrayKindAndStaysReadableWithoutIt() throws {
        let schema = try EmptyArrayModel.cloudModelSchema()
        let labels = try #require(schema.field(CloudFieldIdentifier("labels")))
        let optionalLabels = try #require(schema.field(CloudFieldIdentifier("optionalLabels")))
        guard case let .attribute(labelsAttribute) = labels,
              case let .attribute(optionalAttribute) = optionalLabels
        else {
            Issue.record("Both fields must be attributes")
            return
        }
        #expect(labelsAttribute.valueKind == .stringArray)
        #expect(optionalAttribute.valueKind == .stringArray)

        let decoded = try JSONDecoder().decode(
            CloudModelSchema.self,
            from: JSONEncoder().encode(schema)
        )
        #expect(decoded == schema)

        let title = try CloudFieldIdentifier("title")
        let plain = try CloudAttributeSchema(id: title, recordName: title, kind: .scalar)
        let plainJSON = try JSONEncoder().encode(plain)
        #expect(String(decoding: plainJSON, as: UTF8.self).contains("valueKind") == false)
        let legacy = try JSONDecoder().decode(CloudAttributeSchema.self, from: plainJSON)
        #expect(legacy.valueKind == nil)
    }
}
