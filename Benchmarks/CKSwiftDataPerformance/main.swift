import CKSwiftData
import Foundation
import os

@CloudModel(recordType: "PerformanceRecord", schemaVersion: 1)
final class PerformanceRecord {
    var title: String = ""
    var note: String?
}

@main
@MainActor
struct CKSwiftDataPerformance {
    private static let log = OSLog(
        subsystem: "com.stalkermv.CKSwiftData.performance",
        category: "Benchmark"
    )

    static func main() async throws {
        let configuration = try Configuration.parse(arguments: Array(CommandLine.arguments.dropFirst()))
        if configuration.help {
            print(Configuration.usage)
            return
        }

        let zone = try CloudZoneIdentifier("_defaultZone")
        let modelID = try PerformanceRecord.cloudModelIdentifier()
        let titleField = try CloudFieldIdentifier("title")
        let noteField = try CloudFieldIdentifier("note")
        let initial = try makeInitialRecords(
            count: configuration.records,
            zone: zone,
            modelID: modelID,
            titleField: titleField,
            noteField: noteField
        )
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: initial)
        let container = try CloudModelContainer(
            schema: CloudSchema(models: [PerformanceRecord.cloudModelSchema()]),
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.CKSwiftDataPerformance"),
                location: .privateDatabase(.default)
            ),
            client: client
        )
        let descriptor = try CloudFetchDescriptor<PerformanceRecord>(limit: configuration.pageSize)

        print("scenario=typed-fetch-save records=\(configuration.records) iterations=\(configuration.iterations) page_size=\(configuration.pageSize)")
        print("phase\titeration\tmilliseconds\tpages\tmodels")

        for warmup in 0 ..< configuration.warmupIterations {
            _ = try await measure("Warmup") {
                try await fetchAll(
                    descriptor: descriptor,
                    context: container.mainContext
                )
            }
            print("warmup\t\(warmup + 1)\tcompleted")
        }

        for iteration in 0 ..< configuration.iterations {
            let ((models, pageCount), fetchMilliseconds) = try await measure("Fetch") {
                try await fetchAll(
                    descriptor: descriptor,
                    context: container.mainContext
                )
            }
            for (index, model) in models.enumerated() where index % configuration.editStride == iteration % configuration.editStride {
                model.title = "iteration-\(iteration)-record-\(index)"
                model.note = "profiled"
            }
            let (_, saveMilliseconds) = try await measure("Save") {
                try await container.mainContext.save()
            }
            print("fetch\t\(iteration + 1)\t\(format(fetchMilliseconds))\t\(pageCount)\t\(models.count)")
            print("save\t\(iteration + 1)\t\(format(saveMilliseconds))\t-\t\(models.count)")
        }
    }

    private static func makeInitialRecords(
        count: Int,
        zone: CloudZoneIdentifier,
        modelID: CloudModelIdentifier,
        titleField: CloudFieldIdentifier,
        noteField: CloudFieldIdentifier
    ) throws -> [CloudRecordSnapshot] {
        try (0 ..< count).map { index in
            let id = try CloudRecordIdentifier(
                recordName: "performance-\(index)",
                zone: zone
            )
            return try CloudRecordSnapshot(
                id: id,
                modelID: modelID,
                changeTag: "c\(index + 1)",
                fields: [
                    titleField: .string("initial-\(index)"),
                    noteField: .string("baseline")
                ]
            )
        }
    }

    private static func fetchAll(
        descriptor: CloudFetchDescriptor<PerformanceRecord>,
        context: CloudModelContext
    ) async throws -> (models: [PerformanceRecord], pages: Int) {
        var cursor = descriptor.request.cursor
        var models = [PerformanceRecord]()
        var pages = 0
        repeat {
            let pageDescriptor = try CloudFetchDescriptor<PerformanceRecord>(
                limit: descriptor.request.limit,
                cursor: cursor,
                desiredFields: descriptor.request.desiredFields
            )
            let page = try await context.fetch(pageDescriptor)
            models.append(contentsOf: page.models)
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil
        return (models, pages)
    }

    private static func measure<Value>(
        _ name: StaticString,
        operation: @MainActor () async throws -> Value
    ) async throws -> (Value, Double) {
        let signpostID = OSSignpostID(log: log)
        let clock = ContinuousClock()
        let start = clock.now
        os_signpost(.begin, log: log, name: name, signpostID: signpostID)
        defer {
            os_signpost(.end, log: log, name: name, signpostID: signpostID)
        }
        let value = try await operation()
        let elapsed = start.duration(to: clock.now)
        let components = elapsed.components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return (value, milliseconds)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private struct Configuration {
        let records: Int
        let iterations: Int
        let pageSize: Int
        let warmupIterations: Int
        let editStride: Int
        let help: Bool

        static func parse(arguments: [String]) throws -> Configuration {
            if arguments.contains("--help") || arguments.contains("-h") {
                return Configuration(
                    records: 1,
                    iterations: 1,
                    pageSize: 1,
                    warmupIterations: 0,
                    editStride: 1,
                    help: true
                )
            }
            return try Configuration(
                records: value(for: "--records", in: arguments, default: 5_000),
                iterations: value(for: "--iterations", in: arguments, default: 5),
                pageSize: value(for: "--page-size", in: arguments, default: 250),
                warmupIterations: value(for: "--warmup", in: arguments, default: 1),
                editStride: value(for: "--edit-stride", in: arguments, default: 10),
                help: false
            )
        }

        private static func value(
            for name: String,
            in arguments: [String],
            default defaultValue: Int
        ) throws -> Int {
            guard let position = arguments.firstIndex(of: name) else { return defaultValue }
            guard arguments.indices.contains(position + 1),
                  let value = Int(arguments[position + 1]),
                  value > 0
            else {
                throw NSError(
                    domain: "CKSwiftDataPerformance",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected a positive integer after \(name)"]
                )
            }
            return value
        }

        static let usage = """
        CKSwiftDataPerformance

        Runs a deterministic typed fetch/save workload against the in-memory
        CloudKit client. Each measured phase emits an os_signpost interval.

        Options:
          --records N       Number of records (default: 5000)
          --iterations N   Measured fetch/save pairs (default: 5)
          --page-size N    Records per fetch page (default: 250)
          --warmup N       Unmeasured warmup iterations (default: 1)
          --edit-stride N  Edit every Nth model (default: 10)
        """
    }
}
