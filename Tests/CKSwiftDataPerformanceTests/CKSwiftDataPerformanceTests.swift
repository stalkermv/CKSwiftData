import CKSwiftData
import XCTest

@CloudModel(recordType: "PerformanceRecord", schemaVersion: 1)
final class CKSwiftDataPerformanceRecord {
    var title: String = ""
    var note: String?
}

final class CKSwiftDataPerformanceTests: XCTestCase {
    private let recordCount = 2_000
    private var models = [CKSwiftDataPerformanceRecord]()
    private var snapshots = [CloudRecordSnapshot]()
    private var zone: CloudZoneIdentifier!

    override func setUpWithError() throws {
        try super.setUpWithError()
        zone = try CloudZoneIdentifier("_defaultZone")
        snapshots = try makeSnapshots(count: recordCount, zone: zone)
        models = try snapshots.map {
            try CKSwiftDataPerformanceRecord.makeCloudModel(from: $0, in: zone)
        }
    }

    func testCloudRecordSnapshotPerformance() {
        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric(),
            XCTMemoryMetric()
        ]) {
            var snapshots = [CloudRecordSnapshot]()
            snapshots.reserveCapacity(models.count)
            for model in models {
                do {
                    try snapshots.append(model.cloudRecordSnapshot(in: zone))
                } catch {
                    XCTFail("Snapshot conversion failed: \(error)")
                    return
                }
            }
            XCTAssertEqual(snapshots.count, models.count)
        }
    }

    func testCloudModelMaterializationPerformance() {
        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric(),
            XCTMemoryMetric()
        ]) {
            for snapshot in snapshots {
                do {
                    _ = try CKSwiftDataPerformanceRecord.makeCloudModel(
                        from: snapshot,
                        in: zone
                    )
                } catch {
                    XCTFail("Model materialization failed: \(error)")
                    return
                }
            }
        }
    }

    private func makeSnapshots(
        count: Int,
        zone: CloudZoneIdentifier
    ) throws -> [CloudRecordSnapshot] {
        let modelID = try CKSwiftDataPerformanceRecord.cloudModelIdentifier()
        let title = try CloudFieldIdentifier("title")
        let note = try CloudFieldIdentifier("note")
        return try (0 ..< count).map { index in
            let id = try CloudRecordIdentifier(
                recordName: "performance-\(index)",
                zone: zone
            )
            let snapshot = try CloudRecordSnapshot(
                id: id,
                modelID: modelID,
                changeTag: "c\(index + 1)",
                fields: [
                    title: .string("initial-\(index)"),
                    note: .string("baseline")
                ]
            )
            return snapshot
        }
    }
}
