import CKSwiftData
import Foundation
import Testing

struct CloudAssetTests {
    @Test
    func stagerUsesUniqueLeasesAndCleansFiles() async throws {
        let stager = try CloudAssetStager()
        let first = try await stager.stage(data: Data("one".utf8), contentType: "text/plain")
        let second = try await stager.stage(data: Data("two".utf8), contentType: "text/plain")

        #expect(first.lease.fileURL != second.lease.fileURL)
        #expect(FileManager.default.fileExists(atPath: first.lease.fileURL.path))
        #expect(await stager.isLeased(first.lease))
        #expect(first.reference.byteCount == 3)
        #expect(first.reference.contentType == "text/plain")

        try await stager.cleanup(first.lease)
        #expect(await stager.isLeased(first.lease) == false)
        #expect(FileManager.default.fileExists(atPath: first.lease.fileURL.path) == false)

        try await stager.cleanup(second.lease)
        #expect(await stager.isLeased(second.lease) == false)
    }

    @Test
    func scopedStagingCleansAfterOperationFailure() async throws {
        let stager = try CloudAssetStager()
        let upload = try await stager.withStagedData(Data("payload".utf8)) { upload in
            upload
        }
        #expect(await stager.isLeased(upload.lease) == false)
        #expect(FileManager.default.fileExists(atPath: upload.lease.fileURL.path) == false)
    }

    @Test
    func assetReferencesRoundTripThroughRecordBoundary() throws {
        let reference = try CloudAssetReference(
            assetID: "asset-1",
            byteCount: 12,
            contentType: "application/octet-stream"
        )
        let value = CloudRecordValue.asset(reference)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(CloudRecordValue.self, from: data)
        #expect(decoded == value)
        #expect(decoded.kind == .asset)
    }

    @Test
    func encodedAssetLeasesCannotBeDecodedWithoutAnOwningStager() async throws {
        let stager = try CloudAssetStager()
        let upload = try await stager.stage(data: Data("payload".utf8))
        let data = try JSONEncoder().encode(upload)

        do {
            _ = try JSONDecoder().decode(CloudAssetUpload.self, from: data)
            Issue.record("An encoded asset lease must not be revived without its stager")
        } catch let error as CloudAssetError {
            #expect(error == .unknownLease(upload.lease.id))
        } catch {
            Issue.record("Unexpected asset decode error: \(error)")
        }
        try await stager.cleanup(upload.lease)
    }
}
