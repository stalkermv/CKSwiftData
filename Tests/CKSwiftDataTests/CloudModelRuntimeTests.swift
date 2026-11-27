import CKSwiftData
import Foundation
import os
import Testing

private enum DynamicModelTestError: Error {
    case unavailable
}

private enum DynamicMacroRuntimeConfig {
    private static let recordTypeState = OSAllocatedUnfairLock(initialState: "MacroDynamicOne")

    static var recordType: String {
        recordTypeState.withLock { $0 }
    }

    static func setRecordType(_ value: String) {
        recordTypeState.withLock { $0 = value }
    }
}

private enum DynamicMacroLiteralRuntimeConfig {
    private static let recordTypeState = OSAllocatedUnfairLock(initialState: "MacroDynamicLiteralOne")

    static var recordType: String {
        recordTypeState.withLock { $0 }
    }

    static func setRecordType(_ value: String) {
        recordTypeState.withLock { $0 = value }
    }
}

private extension String {
    static var unique: String {
        DynamicMacroLiteralRuntimeConfig.recordType
    }
}

@CloudModel(recordType: DynamicMacroRuntimeConfig.recordType)
final class DynamicMacroModel {
    var title: String = ""
}

@CloudModel(recordType: .unique)
final class DynamicMemberMacroModel {
    var title: String = ""
}

@CloudModel(recordType: #"Raw\#(DynamicMacroLiteralRuntimeConfig.recordType)"#)
final class RawInterpolatedMacroModel {
    var title: String = ""
}

@CloudModel
final class OmittedRecordTypeMacroModel {
    var title: String = ""
}

@CloudModel(recordType: "SnapshotApplyModel")
final class SnapshotApplyMacroModel {
    var title: String = ""
    var note: String?
}

private final class DynamicPersistentModel: CloudPersistentModel {
    private static let recordTypeState = OSAllocatedUnfairLock(initialState: "DynamicOne")

    static var cloudRecordType: String {
        recordTypeState.withLock { $0 }
    }

    static func setRecordType(_ value: String) {
        recordTypeState.withLock { $0 = value }
    }

    static func cloudModelSchema() throws -> CloudModelSchema {
        throw DynamicModelTestError.unavailable
    }

    static func makeCloudModel(
        from snapshot: CloudRecordSnapshot,
        in zone: CloudZoneIdentifier
    ) throws -> Self {
        throw DynamicModelTestError.unavailable
    }

    func cloudRecordIdentifier(in zone: CloudZoneIdentifier) throws -> CloudRecordIdentifier {
        throw DynamicModelTestError.unavailable
    }

    func cloudRecordSnapshot(in zone: CloudZoneIdentifier) throws -> CloudRecordSnapshot {
        throw DynamicModelTestError.unavailable
    }

    func applyCloudRecordSnapshot(_ snapshot: CloudRecordSnapshot) throws {
        throw DynamicModelTestError.unavailable
    }
}

@MainActor
struct CloudModelRuntimeTests {
    @Test
    func snapshotValidationPrecedesMutationAndPreservesPartialSemantics() throws {
        let zone = try CloudZoneIdentifier("private")
        let title = try CloudFieldIdentifier("title")
        let note = try CloudFieldIdentifier("note")
        let unknown = try CloudFieldIdentifier("unknown")
        let modelID = try SnapshotApplyMacroModel.cloudModelIdentifier()
        let id = try CloudRecordIdentifier(recordName: "snapshot-1", zone: zone)
        let model = try SnapshotApplyMacroModel.makeCloudModel(
            from: CloudRecordSnapshot(
                id: id,
                modelID: modelID,
                changeTag: "c1",
                fields: [
                    title: .string("initial"),
                    note: .string("preserved")
                ]
            ),
            in: zone
        )

        do {
            try model.applyCloudRecordSnapshot(CloudRecordSnapshot(
                id: id,
                modelID: modelID,
                fields: [
                    title: .string("must-not-apply"),
                    unknown: .string("invalid")
                ]
            ))
            Issue.record("An unknown field must reject the whole snapshot")
        } catch let error as CloudModelRuntimeError {
            #expect(error == .unknownField(unknown))
        }
        let rejected = try model.cloudRecordSnapshot(in: zone)
        #expect(rejected.fields[title] == .string("initial"))
        #expect(rejected.fields[note] == .string("preserved"))

        try model.applyCloudRecordSnapshot(CloudRecordSnapshot(
            id: id,
            modelID: modelID,
            fields: [title: .string("partial")],
            isPartial: true
        ))
        let partial = try model.cloudRecordSnapshot(in: zone)
        #expect(partial.fields[title] == .string("partial"))
        #expect(partial.fields[note] == .string("preserved"))

        try model.applyCloudRecordSnapshot(CloudRecordSnapshot(
            id: id,
            modelID: modelID,
            fields: [title: .string("complete")]
        ))
        let complete = try model.cloudRecordSnapshot(in: zone)
        #expect(complete.fields[title] == .string("complete"))
        #expect(complete.fields[note] == nil)
    }

    @Test
    func customDynamicRecordTypeIsNotFrozenByRuntimeCache() throws {
        DynamicPersistentModel.setRecordType("DynamicOne")
        let first = try DynamicPersistentModel.cloudModelIdentifier()

        DynamicPersistentModel.setRecordType("DynamicTwo")
        let second = try DynamicPersistentModel.cloudModelIdentifier()

        #expect(first != second)
        #expect(second.rawValue == "DynamicTwo")
    }

    @Test
    func macroDynamicRecordTypeDoesNotOptIntoRuntimeCache() throws {
        DynamicMacroRuntimeConfig.setRecordType("MacroDynamicOne")
        #expect(DynamicMacroModel.recordType == "MacroDynamicOne")
        #expect(DynamicMacroModel.cloudModelRuntimeMetadataIsStable == false)
    }

    @Test
    func dynamicLiteralFormsDoNotOptIntoRuntimeCache() {
        DynamicMacroLiteralRuntimeConfig.setRecordType("MacroDynamicLiteralOne")
        #expect(DynamicMemberMacroModel.recordType == "MacroDynamicLiteralOne")
        #expect(RawInterpolatedMacroModel.recordType == "RawMacroDynamicLiteralOne")
        #expect(DynamicMemberMacroModel.cloudModelRuntimeMetadataIsStable == false)
        #expect(RawInterpolatedMacroModel.cloudModelRuntimeMetadataIsStable == false)
    }

    @Test
    func dynamicRecordTypeIsUsedForTheRuntimeRecordType() throws {
        DynamicMacroLiteralRuntimeConfig.setRecordType("MacroDynamicLiteralOne")
        #expect(DynamicMemberMacroModel.cloudRecordType == "MacroDynamicLiteralOne")
        #expect(try DynamicMemberMacroModel.cloudModelIdentifier().rawValue == "MacroDynamicLiteralOne")
    }

    @Test
    func omittedRecordTypeIsTheClassNameAndOptsIntoRuntimeCache() throws {
        #expect(OmittedRecordTypeMacroModel.recordType == "OmittedRecordTypeMacroModel")
        #expect(OmittedRecordTypeMacroModel.cloudRecordType == "OmittedRecordTypeMacroModel")
        #expect(OmittedRecordTypeMacroModel.cloudModelRuntimeMetadataIsStable)
        let first = try OmittedRecordTypeMacroModel.cloudModelIdentifier()
        let second = try OmittedRecordTypeMacroModel.cloudModelIdentifier()
        #expect(first == second)
    }
}
