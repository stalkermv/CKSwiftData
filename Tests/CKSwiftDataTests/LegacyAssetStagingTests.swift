@testable import CKSwiftData
import CloudKit
import Foundation
import Testing

struct LegacyAssetStagingTests {
    private struct FailingEncodable: Encodable {
        struct Failure: Error {}

        func encode(to encoder: any Encoder) throws {
            throw Failure()
        }
    }

    @Test
    func assetsWithTheSameNameUseDistinctFiles() throws {
        let first = try CKAsset(encodable: "first", fileName: "payload", fileExtension: "data")
        let second = try CKAsset(encodable: "second", fileName: "payload", fileExtension: "data")
        let firstURL = try #require(first.fileURL)
        let secondURL = try #require(second.fileURL)
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        #expect(firstURL != secondURL)
        #expect(firstURL.lastPathComponent == "payload.data")
        #expect(try JSONDecoder().decode(String.self, from: Data(contentsOf: firstURL)) == "first")
        #expect(try JSONDecoder().decode(String.self, from: Data(contentsOf: secondURL)) == "second")
    }

    @Test
    func concurrentAssetCreationDoesNotOverwriteFiles() async throws {
        let assets = try await withThrowingTaskGroup(of: (Int, CKAsset).self) { group in
            for index in 0 ..< 16 {
                group.addTask {
                    try (index, CKAsset(encodable: index, fileName: "payload", fileExtension: "data"))
                }
            }
            var results: [(Int, CKAsset)] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
        let urls = try assets.map { try #require($0.1.fileURL) }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        #expect(Set(urls).count == assets.count)
        for (index, asset) in assets {
            let url = try #require(asset.fileURL)
            #expect(try JSONDecoder().decode(Int.self, from: Data(contentsOf: url)) == index)
        }
    }

    @Test
    func encodingFailureIsThrownInsteadOfTerminatingTheProcess() {
        #expect(throws: FailingEncodable.Failure.self) {
            _ = try CKAsset(encodable: FailingEncodable(), fileName: "payload", fileExtension: "data")
        }
    }
}
