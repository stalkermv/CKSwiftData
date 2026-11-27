@testable import CKSwiftData
import CloudKit
import Testing

struct CloudReferenceZoneTests {
    private let field: CloudFieldIdentifier
    private let configured: CloudZoneIdentifier

    init() throws {
        field = try CloudFieldIdentifier("parent")
        configured = try CloudZoneIdentifier("AppData")
    }

    private func reference(to recordName: String, inZone zoneName: String?) -> CKRecord.Reference {
        let recordID = zoneName.map {
            CKRecord.ID(
                recordName: recordName,
                zoneID: CKRecordZone.ID(zoneName: $0, ownerName: CKCurrentUserDefaultName)
            )
        } ?? CKRecord.ID(recordName: recordName)
        return CKRecord.Reference(recordID: recordID, action: .none)
    }

    @Test
    func unplacedReferenceTakesTheConfiguredZone() throws {
        let value = try CloudRecordValue(
            cloudKitValue: reference(to: "task-1", inZone: nil),
            fieldID: field,
            zoneOverride: configured
        )
        #expect(value == .reference(try CloudRecordIdentifier(recordName: "task-1", zone: configured)))
    }

    @Test
    func referenceInTheConfiguredZoneIsKept() throws {
        let value = try CloudRecordValue(
            cloudKitValue: reference(to: "task-1", inZone: "AppData"),
            fieldID: field,
            zoneOverride: configured
        )
        #expect(value == .reference(try CloudRecordIdentifier(recordName: "task-1", zone: configured)))
    }

    @Test
    func referenceToAnotherZoneIsNotRedirected() throws {
        #expect(throws: CloudModelRuntimeError.self) {
            try CloudRecordValue(
                cloudKitValue: reference(to: "task-1", inZone: "Archive"),
                fieldID: field,
                zoneOverride: configured
            )
        }
        #expect(throws: CloudModelRuntimeError.self) {
            try CloudRecordValue(
                cloudKitValue: [
                    reference(to: "task-1", inZone: "AppData"),
                    reference(to: "task-2", inZone: "Archive")
                ],
                fieldID: field,
                zoneOverride: configured
            )
        }
    }

    @Test
    func referenceKeepsItsOwnZoneWithoutAnOverride() throws {
        let archive = try CloudZoneIdentifier("Archive")
        let value = try CloudRecordValue(
            cloudKitValue: reference(to: "task-1", inZone: "Archive"),
            fieldID: field
        )
        #expect(value == .reference(try CloudRecordIdentifier(recordName: "task-1", zone: archive)))
    }
}
