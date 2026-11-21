@testable import CKSwiftData
import CloudKit
import Foundation
import Testing

struct CloudValueCodecTests {
    private struct Payload: Codable, Equatable, Sendable {
        let title: String
        let count: Int
    }

    @Test
    func jsonCodecRoundTripsCodableSendableValuesAsData() throws {
        let codec = CloudJSONRecordValueCodec<Payload>()
        let payload = Payload(title: "hello", count: 3)

        let encoded = try codec.encode(payload)
        let decoded = try codec.decode(encoded)

        #expect(encoded.kind == .data)
        #expect(decoded == payload)
    }

    @Test
    func jsonCodecRejectsNonDataRecordValues() throws {
        let codec = CloudJSONRecordValueCodec<Payload>()

        do {
            _ = try codec.decode(.string("not encoded payload"))
            Issue.record("A JSON codec must reject scalar values that are not data")
        } catch let error as CloudValueCodecError {
            #expect(error == .expectedData(actual: .string))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func cloudKitNSNumberBridgePreservesScalarAndReferenceArrayKinds() throws {
        let record = CKRecord(recordType: "ScalarKinds")
        record["flag"] = true
        record["wholeDouble"] = 1.0
        record["wholeInt"] = Int64(1)
        record["smallInt"] = Int8(2)

        let flag = try CloudRecordValue(
            cloudKitValue: #require(record["flag"]),
            fieldID: CloudFieldIdentifier("flag")
        )
        let wholeDouble = try CloudRecordValue(
            cloudKitValue: #require(record["wholeDouble"]),
            fieldID: CloudFieldIdentifier("wholeDouble")
        )
        let wholeInt = try CloudRecordValue(
            cloudKitValue: #require(record["wholeInt"]),
            fieldID: CloudFieldIdentifier("wholeInt")
        )
        let smallInt = try CloudRecordValue(
            cloudKitValue: #require(record["smallInt"]),
            fieldID: CloudFieldIdentifier("smallInt")
        )
        let emptyReferences: [CKRecord.Reference] = []
        let emptyReferenceValue = try CloudRecordValue(
            cloudKitValue: emptyReferences,
            fieldID: CloudFieldIdentifier("references"),
            expectedKind: .referenceArray
        )

        #expect(flag == .bool(true))
        #expect(wholeDouble == .double(1.0))
        #expect(wholeInt == .int64(1))
        #expect(smallInt == .int64(2))
        #expect(emptyReferenceValue == .referenceArray([]))
    }

    @Test
    func cloudKitEncryptedValuesRequireMapAwareReplacementOrder() throws {
        let record = CKRecord(recordType: "EncryptedFields")

        // Plaintext -> encrypted must remove the normal value first.
        record["secret"] = "plain"
        if record.encryptedValues["secret"] != nil {
            record.encryptedValues["secret"] = nil
        }
        if record["secret"] != nil {
            record["secret"] = nil
        }
        record.encryptedValues["secret"] = "encrypted"
        #expect(record["secret"] == nil)
        #expect(record.encryptedValues["secret"] as? String == "encrypted")

        // Encrypted -> encrypted must clear encryptedValues first; assigning
        // through the normal subscript while it is still populated raises a
        // CKException rather than a Swift error.
        if record.encryptedValues["secret"] != nil {
            record.encryptedValues["secret"] = nil
        }
        if record["secret"] != nil {
            record["secret"] = nil
        }
        record.encryptedValues["secret"] = "replacement"
        #expect(record.encryptedValues["secret"] as? String == "replacement")

        // Removal follows the same ordering and leaves both maps empty.
        if record.encryptedValues["secret"] != nil {
            record.encryptedValues["secret"] = nil
        }
        if record["secret"] != nil {
            record["secret"] = nil
        }
        #expect(record["secret"] == nil)
        #expect(record.encryptedValues["secret"] == nil)
    }
}
