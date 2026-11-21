import Foundation

public struct CloudMigrationCheckpoint: Codable, Hashable, Sendable {
    public let migrationID: UUID
    public let stageIndex: Int
    public let cursor: CloudPageCursor?
    public let processedRecords: Int
    public let completed: Bool

    public init(
        migrationID: UUID,
        stageIndex: Int = 0,
        cursor: CloudPageCursor? = nil,
        processedRecords: Int = 0,
        completed: Bool = false
    ) throws {
        guard stageIndex >= 0 else { throw CloudMigrationError.invalidStageIndex(stageIndex) }
        guard processedRecords >= 0 else {
            throw CloudMigrationError.invalidProcessedCount(processedRecords)
        }
        self.migrationID = migrationID
        self.stageIndex = stageIndex
        self.cursor = cursor
        self.processedRecords = processedRecords
        self.completed = completed
    }

    private enum CodingKeys: String, CodingKey {
        case migrationID
        case stageIndex
        case cursor
        case processedRecords
        case completed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            migrationID: container.decode(UUID.self, forKey: .migrationID),
            stageIndex: container.decode(Int.self, forKey: .stageIndex),
            cursor: container.decodeIfPresent(CloudPageCursor.self, forKey: .cursor),
            processedRecords: container.decode(Int.self, forKey: .processedRecords),
            completed: container.decode(Bool.self, forKey: .completed)
        )
    }

    public func advancing(
        stageIndex: Int,
        cursor: CloudPageCursor?,
        processedRecords: Int,
        completed: Bool = false
    ) throws -> CloudMigrationCheckpoint {
        try CloudMigrationCheckpoint(
            migrationID: migrationID,
            stageIndex: stageIndex,
            cursor: cursor,
            processedRecords: processedRecords,
            completed: completed
        )
    }
}

/// Persists checkpoint progress after every executor step and rejects skipped
/// or non-progressing stages. CloudKit-specific backfill behavior is injected
/// through `CloudMigrationStageExecutor`, keeping deployment policy explicit.
public actor CloudMigrationCoordinator {
    private let checkpointStore: any CloudMigrationCheckpointStore
    private var runningMigrations: Set<UUID> = []

    public init(checkpointStore: any CloudMigrationCheckpointStore) {
        self.checkpointStore = checkpointStore
    }

    public func run(
        _ plan: CloudMigrationPlan,
        using executor: any CloudMigrationStageExecutor
    ) async throws -> CloudMigrationCheckpoint {
        guard runningMigrations.insert(plan.id).inserted else {
            throw CloudMigrationError.migrationAlreadyRunning(plan.id)
        }
        defer { runningMigrations.remove(plan.id) }

        var checkpoint = try await checkpointStore.load(migrationID: plan.id)
            ?? CloudMigrationCheckpoint(migrationID: plan.id)
        guard checkpoint.migrationID == plan.id else {
            throw CloudMigrationError.checkpointMigrationMismatch(checkpoint.migrationID)
        }
        guard checkpoint.stageIndex <= plan.stages.count else {
            throw CloudMigrationError.invalidStageIndex(checkpoint.stageIndex)
        }
        if checkpoint.completed {
            return checkpoint
        }
        if checkpoint.stageIndex == plan.stages.count {
            checkpoint = try CloudMigrationCheckpoint(
                migrationID: plan.id,
                stageIndex: checkpoint.stageIndex,
                cursor: checkpoint.cursor,
                processedRecords: checkpoint.processedRecords,
                completed: true
            )
            try await checkpointStore.save(checkpoint)
            return checkpoint
        }

        while checkpoint.stageIndex < plan.stages.count {
            let currentIndex = checkpoint.stageIndex
            let next = try await executor.execute(
                plan.stages[currentIndex],
                checkpoint: checkpoint
            )
            guard next.migrationID == plan.id else {
                throw CloudMigrationError.checkpointMigrationMismatch(next.migrationID)
            }
            guard next.stageIndex == currentIndex || next.stageIndex == currentIndex + 1 else {
                throw CloudMigrationError.invalidStageProgress(
                    stageIndex: currentIndex,
                    nextStageIndex: next.stageIndex
                )
            }
            guard next.processedRecords >= checkpoint.processedRecords else {
                throw CloudMigrationError.invalidProcessedCount(next.processedRecords)
            }
            if next.stageIndex == currentIndex,
               next.cursor == checkpoint.cursor,
               next.processedRecords == checkpoint.processedRecords
            {
                throw CloudMigrationError.invalidStageProgress(
                    stageIndex: currentIndex,
                    nextStageIndex: next.stageIndex
                )
            }
            checkpoint = try CloudMigrationCheckpoint(
                migrationID: plan.id,
                stageIndex: next.stageIndex,
                cursor: next.cursor,
                processedRecords: next.processedRecords,
                completed: next.stageIndex == plan.stages.count
            )
            try await checkpointStore.save(checkpoint)
        }
        return checkpoint
    }
}

/// An actor-backed checkpoint store for deterministic tests and previews.
public actor InMemoryCloudMigrationCheckpointStore: CloudMigrationCheckpointStore {
    private var checkpoints: [UUID: CloudMigrationCheckpoint] = [:]

    public init() {}

    public func load(migrationID: UUID) async throws -> CloudMigrationCheckpoint? {
        checkpoints[migrationID]
    }

    public func save(_ checkpoint: CloudMigrationCheckpoint) async throws {
        checkpoints[checkpoint.migrationID] = checkpoint
    }
}
