import Foundation

public enum CloudAssetError: Error, Codable, Equatable, Hashable, Sendable {
    case emptyIdentifier
    case invalidByteCount(Int64)
    case emptyContentType
    case sourceIsNotAFile(URL)
    case unableToPrepareDirectory(URL)
    case unknownLease(UUID)
    case destinationExists(URL)
    case cancelled
}

/// Remote-safe asset metadata. It does not contain a temporary local path.
public struct CloudAssetReference: Codable, Hashable, Sendable {
    public let assetID: String
    public let byteCount: Int64?
    public let contentType: String?

    public init(
        assetID: String,
        byteCount: Int64? = nil,
        contentType: String? = nil
    ) throws {
        let normalizedID = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedID.isEmpty == false else { throw CloudAssetError.emptyIdentifier }
        if let byteCount, byteCount < 0 {
            throw CloudAssetError.invalidByteCount(byteCount)
        }
        let normalizedContentType = contentType?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedContentType, normalizedContentType.isEmpty {
            throw CloudAssetError.emptyContentType
        }
        self.assetID = normalizedID
        self.byteCount = byteCount
        self.contentType = normalizedContentType
    }

    private enum CodingKeys: String, CodingKey {
        case assetID
        case byteCount
        case contentType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            assetID: container.decode(String.self, forKey: .assetID),
            byteCount: container.decodeIfPresent(Int64.self, forKey: .byteCount),
            contentType: container.decodeIfPresent(String.self, forKey: .contentType)
        )
    }
}

/// A uniquely named local file owned by an asset stager until cleanup.
public struct CloudAssetLease: Codable, Hashable, Sendable {
    public let id: UUID
    public let fileURL: URL

    fileprivate init(id: UUID, fileURL: URL) {
        self.id = id
        self.fileURL = fileURL
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case fileURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        _ = try container.decode(URL.self, forKey: .fileURL)
        // A lease is an actor-owned capability. Decoding its bytes cannot
        // recreate membership in a live CloudAssetStager, so fail closed
        // instead of manufacturing an unowned cleanup token.
        throw CloudAssetError.unknownLease(id)
    }
}

public struct CloudAssetUpload: Codable, Hashable, Sendable {
    public let reference: CloudAssetReference
    public let lease: CloudAssetLease

    fileprivate init(reference: CloudAssetReference, lease: CloudAssetLease) {
        self.reference = reference
        self.lease = lease
    }

    private enum CodingKeys: String, CodingKey {
        case reference
        case lease
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(CloudAssetReference.self, forKey: .reference)
        let lease = try container.decode(CloudAssetLease.self, forKey: .lease)
        throw CloudAssetError.unknownLease(lease.id)
    }
}

public struct CloudAssetMutationKey: Codable, Hashable, Sendable {
    public let recordID: CloudRecordIdentifier
    public let fieldID: CloudFieldIdentifier

    public init(recordID: CloudRecordIdentifier, fieldID: CloudFieldIdentifier) {
        self.recordID = recordID
        self.fieldID = fieldID
    }
}

/// An actor-isolated owner for temporary asset files.
///
/// Every staged file has a UUID-based path. Cleanup is explicit and is also
/// performed by `withStagedData` on both success and failure, including task
/// cancellation paths.
public actor CloudAssetStager {
    private let rootURL: URL
    private let removesRootOnDeinit: Bool
    private var leases: [UUID: CloudAssetLease] = [:]

    public init(directory: URL? = nil) throws {
        let root: URL
        let removesRoot: Bool
        if let directory {
            root = directory
            removesRoot = false
        } else {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CKSwiftDataAssets-\(UUID().uuidString)", isDirectory: true)
            removesRoot = true
        }
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        } catch {
            throw CloudAssetError.unableToPrepareDirectory(root)
        }
        rootURL = root
        removesRootOnDeinit = removesRoot
    }

    deinit {
        guard removesRootOnDeinit else { return }
        try? FileManager.default.removeItem(at: rootURL)
    }

    public func stage(
        data: Data,
        contentType: String? = nil
    ) async throws -> CloudAssetUpload {
        do {
            try Task.checkCancellation()
        } catch {
            throw CloudAssetError.cancelled
        }
        let id = UUID()
        let fileURL = rootURL.appendingPathComponent("asset-\(id.uuidString).bin")
        let lease = CloudAssetLease(id: id, fileURL: fileURL)
        do {
            try data.write(to: fileURL, options: .atomic)
            try Task.checkCancellation()
            let reference = try CloudAssetReference(
                assetID: id.uuidString,
                byteCount: Int64(data.count),
                contentType: contentType
            )
            leases[id] = lease
            return CloudAssetUpload(reference: reference, lease: lease)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: fileURL)
            throw CloudAssetError.cancelled
        } catch let error as CloudAssetError {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    public func stage(
        fileAt sourceURL: URL,
        contentType: String? = nil
    ) async throws -> CloudAssetUpload {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue == false
        else {
            throw CloudAssetError.sourceIsNotAFile(sourceURL)
        }
        do {
            try Task.checkCancellation()
        } catch {
            throw CloudAssetError.cancelled
        }
        let id = UUID()
        let fileURL = rootURL.appendingPathComponent("asset-\(id.uuidString).bin")
        let lease = CloudAssetLease(id: id, fileURL: fileURL)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: fileURL)
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let byteCount = (attributes[.size] as? NSNumber).map(\.int64Value)
            let reference = try CloudAssetReference(
                assetID: id.uuidString,
                byteCount: byteCount,
                contentType: contentType
            )
            leases[id] = lease
            return CloudAssetUpload(reference: reference, lease: lease)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: fileURL)
            throw CloudAssetError.cancelled
        } catch let error as CloudAssetError {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    /// Copies downloaded bytes to a uniquely named managed file.
    public func materialize(
        data: Data,
        reference: CloudAssetReference
    ) async throws -> CloudAssetUpload {
        let upload = try await stage(data: data, contentType: reference.contentType)
        return upload
    }

    public func cleanup(_ lease: CloudAssetLease) throws {
        guard let ownedLease = leases[lease.id], ownedLease == lease else {
            throw CloudAssetError.unknownLease(lease.id)
        }
        if FileManager.default.fileExists(atPath: ownedLease.fileURL.path) {
            try FileManager.default.removeItem(at: ownedLease.fileURL)
        }
        leases.removeValue(forKey: lease.id)
    }

    public func isLeased(_ lease: CloudAssetLease) -> Bool {
        leases[lease.id] == lease
    }

    public func withStagedData<Result: Sendable>(
        _ data: Data,
        contentType: String? = nil,
        operation: @Sendable (CloudAssetUpload) async throws -> Result
    ) async throws -> Result {
        let upload = try await stage(data: data, contentType: contentType)
        do {
            let result = try await operation(upload)
            try cleanup(upload.lease)
            return result
        } catch let operationError {
            do {
                try cleanup(upload.lease)
            } catch let cleanupError {
                throw cleanupError
            }
            throw operationError
        }
    }
}
