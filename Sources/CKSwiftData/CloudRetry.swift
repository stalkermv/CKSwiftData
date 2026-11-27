import Foundation

public enum CloudRetryPolicyError: Error, Codable, Equatable, Hashable, Sendable {
    case invalidAttemptCount(Int)
    case invalidDelay(TimeInterval)
    case invalidMultiplier(Double)
}

/// Bounded retry configuration for transient CloudKit operations.
public struct CloudRetryPolicy: Codable, Hashable, Sendable {
    public let maxAttempts: Int
    public let initialDelay: TimeInterval
    public let maximumDelay: TimeInterval
    public let multiplier: Double

    public init(
        maxAttempts: Int = 1,
        initialDelay: TimeInterval = 0,
        maximumDelay: TimeInterval = 60,
        multiplier: Double = 2
    ) throws {
        guard maxAttempts > 0 else {
            throw CloudRetryPolicyError.invalidAttemptCount(maxAttempts)
        }
        guard initialDelay.isFinite,
              maximumDelay.isFinite,
              initialDelay >= 0,
              maximumDelay >= 0,
              maximumDelay >= initialDelay
        else {
            throw CloudRetryPolicyError.invalidDelay(max(initialDelay, maximumDelay))
        }
        guard multiplier >= 1, multiplier.isFinite else {
            throw CloudRetryPolicyError.invalidMultiplier(multiplier)
        }
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.multiplier = multiplier
    }

    private enum CodingKeys: String, CodingKey {
        case maxAttempts
        case initialDelay
        case maximumDelay
        case multiplier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maxAttempts: container.decode(Int.self, forKey: .maxAttempts),
            initialDelay: container.decode(TimeInterval.self, forKey: .initialDelay),
            maximumDelay: container.decode(TimeInterval.self, forKey: .maximumDelay),
            multiplier: container.decode(Double.self, forKey: .multiplier)
        )
    }

    private init(
        maxAttempts: Int,
        initialDelay: TimeInterval,
        maximumDelay: TimeInterval,
        multiplier: Double,
        validated: Bool
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.multiplier = multiplier
    }

    public static let none = CloudRetryPolicy(
        maxAttempts: 1,
        initialDelay: 0,
        maximumDelay: 0,
        multiplier: 1,
        validated: true
    )

    public static let immediate = CloudRetryPolicy(
        maxAttempts: 3,
        initialDelay: 0,
        maximumDelay: 0,
        multiplier: 1,
        validated: true
    )

    public func delay(
        beforeAttempt attempt: Int,
        serverRetryAfter: TimeInterval? = nil
    ) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let calculated = min(
            maximumDelay,
            initialDelay * pow(multiplier, Double(exponent))
        )
        guard let serverRetryAfter, serverRetryAfter.isFinite, serverRetryAfter >= 0 else {
            return calculated
        }
        return min(maximumDelay, max(calculated, serverRetryAfter))
    }
}

public extension CloudModelError {
    var retryAfter: TimeInterval? {
        guard case let .retryable(_, retryAfter) = self else { return nil }
        return retryAfter
    }

    var isRetryable: Bool {
        if case .retryable = self { return true }
        return false
    }
}
