@testable import CKSwiftData
import CloudKit
import Foundation
import Testing

@CloudModel(recordType: "EncryptedAttributes")
final class EncryptedAttributeModel {
    var title: String = ""
    @Attribute(.allowsCloudEncryption)
    var secret: String = ""
    @Attribute(.allowsCloudEncryption)
    var note: String?
}

struct CloudEncryptedAttributeTests {
    private func backing(of model: EncryptedAttributeModel) throws -> CKBackingData<EncryptedAttributeModel> {
        try #require(model.persistentBackingData as? CKBackingData<EncryptedAttributeModel>)
    }

    @Test
    func encryptedAttributesAreWrittenToTheEncryptedMapOnly() throws {
        let model = EncryptedAttributeModel()
        model.title = "visible"
        model.secret = "s3cret"
        model.note = "private note"

        let record = try backing(of: model).record

        #expect(record.encryptedValues["secret"] as? String == "s3cret")
        #expect(record.encryptedValues["note"] as? String == "private note")
        #expect(record["secret"] == nil)
        #expect(record["note"] == nil)
        #expect(record["title"] as? String == "visible")
        #expect(record.encryptedValues["title"] == nil)
    }

    @Test
    func encryptedAttributesAreReadFromAFetchedRecord() throws {
        let model = EncryptedAttributeModel()
        let backing = try backing(of: model)
        let fetched = CKRecord(recordType: "EncryptedAttributes", recordID: backing.record.recordID)
        fetched.encryptedValues["secret"] = "from server"
        fetched.encryptedValues["note"] = "server note"
        backing.record = fetched

        #expect(model.secret == "from server")
        #expect(model.note == "server note")
    }

    @Test
    func clearingAnEncryptedAttributeClearsTheEncryptedMap() throws {
        let model = EncryptedAttributeModel()
        model.note = "temporary"
        model.note = nil

        let record = try backing(of: model).record
        #expect(record.encryptedValues["note"] == nil)
        #expect(record["note"] == nil)
        #expect(model.note == nil)
    }

    @Test
    func rewritingAnEncryptedAttributeNeverLeavesTheKeyInBothMaps() throws {
        let model = EncryptedAttributeModel()
        let backing = try backing(of: model)
        let fetched = CKRecord(recordType: "EncryptedAttributes", recordID: backing.record.recordID)
        fetched.encryptedValues["secret"] = "old"
        backing.record = fetched

        model.secret = "new"

        #expect(backing.record.encryptedValues["secret"] as? String == "new")
        #expect(backing.record["secret"] == nil)
    }

    @Test
    func typedSnapshotsReadAndApplyEncryptedAttributesThroughTheEncryptedMap() throws {
        let zone = try CloudZoneIdentifier("_defaultZone")
        let model = EncryptedAttributeModel()
        model.secret = "alpha"

        let snapshot = try model.cloudRecordSnapshot(in: zone)
        #expect(try snapshot.fields[CloudFieldIdentifier("secret")] == .string("alpha"))

        let restored = try EncryptedAttributeModel.makeCloudModel(from: snapshot, in: zone)
        let record = try backing(of: restored).record
        #expect(record.encryptedValues["secret"] as? String == "alpha")
        #expect(record["secret"] == nil)
        #expect(restored.secret == "alpha")

        try restored.applyCloudRecordSnapshot(CloudRecordSnapshot(
            id: snapshot.id,
            modelID: snapshot.modelID,
            fields: [CloudFieldIdentifier("secret"): .string("beta")],
            isPartial: true
        ))
        #expect(record.encryptedValues["secret"] as? String == "beta")
        #expect(record["secret"] == nil)
    }
}
