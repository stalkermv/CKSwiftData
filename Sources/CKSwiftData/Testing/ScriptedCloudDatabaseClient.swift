import Foundation

extension CKSwiftDataTesting {
    /// A deterministic failure driver for retry and cancellation tests.
    public actor ScriptedCloudDatabaseClient: CloudDatabaseClient {
        private let base: any CloudDatabaseClient
        private var fetchFailures: [CloudModelError]
        private var modifyFailures: [CloudModelError]

        public init(
            base: any CloudDatabaseClient,
            fetchFailures: [CloudModelError] = [],
            modifyFailures: [CloudModelError] = []
        ) {
            self.base = base
            self.fetchFailures = fetchFailures
            self.modifyFailures = modifyFailures
        }

        public func fetch(_ request: CloudRecordFetchRequest) async throws -> CloudRecordPage {
            if fetchFailures.isEmpty == false {
                throw fetchFailures.removeFirst()
            }
            return try await base.fetch(request)
        }

        public func modify(
            saving mutations: [CloudRecordMutation],
            deleting recordIDs: [CloudRecordIdentifier],
            atomic: Bool
        ) async throws -> CloudModifyResult {
            if modifyFailures.isEmpty == false {
                throw modifyFailures.removeFirst()
            }
            return try await base.modify(
                saving: mutations,
                deleting: recordIDs,
                atomic: atomic
            )
        }

        public func appendFetchFailure(_ error: CloudModelError) {
            fetchFailures.append(error)
        }

        public func appendModifyFailure(_ error: CloudModelError) {
            modifyFailures.append(error)
        }
    }
}
