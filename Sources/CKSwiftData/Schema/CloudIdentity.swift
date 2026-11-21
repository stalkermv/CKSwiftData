import Foundation

public enum CloudIdentityError: Error, Equatable, Sendable {
    case empty
    case invalidCharacters(String)
    case invalidContainerIdentifier(String)
}

private func trimmed(_ rawValue: String) throws -> String {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.isEmpty == false else { throw CloudIdentityError.empty }
    return value
}

private func validatedSchemaKey(_ rawValue: String) throws -> String {
    let value = try trimmed(rawValue)
    guard value.utf8.count <= 255,
          let first = value.utf8.first,
          (first >= 65 && first <= 90) || (first >= 97 && first <= 122),
          value.utf8.dropFirst().allSatisfy({
              ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                  ($0 >= 48 && $0 <= 57) || $0 == 95
          })
    else {
        throw CloudIdentityError.invalidCharacters(value)
    }
    return value
}

private func validatedASCIIName(_ rawValue: String, allowsLeadingUnderscore: Bool = false) throws -> String {
    let value = try trimmed(rawValue)
    let bytes = Array(value.utf8)
    guard bytes.count <= 255,
          bytes.allSatisfy({ $0 >= 33 && $0 <= 126 }),
          allowsLeadingUnderscore || bytes.first != 95
    else {
        throw CloudIdentityError.invalidCharacters(value)
    }
    return value
}

private func validatedIdentifier(_ rawValue: String) throws -> String {
    let value = try trimmed(rawValue)

    let allowed = value.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == "."
    }
    guard allowed else { throw CloudIdentityError.invalidCharacters(value) }
    return value
}

public struct CloudModelIdentifier: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        self.rawValue = try validatedSchemaKey(rawValue)
    }

    private enum CodingKeys: String, CodingKey { case rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(String.self, forKey: .rawValue))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct CloudFieldIdentifier: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        self.rawValue = try validatedSchemaKey(rawValue)
    }

    private enum CodingKeys: String, CodingKey { case rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(String.self, forKey: .rawValue))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct CloudZoneIdentifier: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let value = try trimmed(rawValue)
        self.rawValue = try validatedASCIIName(
            value,
            allowsLeadingUnderscore: value == "_defaultZone"
        )
    }

    private enum CodingKeys: String, CodingKey { case rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(String.self, forKey: .rawValue))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct CloudContainerIdentifier: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("iCloud.") else {
            throw CloudIdentityError.invalidContainerIdentifier(value)
        }
        guard value.count > "iCloud.".count else { throw CloudIdentityError.empty }
        self.rawValue = try validatedIdentifier(value)
    }

    private enum CodingKeys: String, CodingKey { case rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(String.self, forKey: .rawValue))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }

    public var description: String { rawValue }
}

public struct CloudRecordIdentifier: Hashable, Codable, Sendable, Comparable {
    public let recordName: String
    public let zone: CloudZoneIdentifier

    public init(recordName: String, zone: CloudZoneIdentifier) throws {
        self.recordName = try validatedASCIIName(recordName)
        self.zone = zone
    }

    private enum CodingKeys: String, CodingKey {
        case recordName
        case zone
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recordName: container.decode(String.self, forKey: .recordName),
            zone: container.decode(CloudZoneIdentifier.self, forKey: .zone)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordName, forKey: .recordName)
        try container.encode(zone, forKey: .zone)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.zone != rhs.zone {
            return lhs.zone < rhs.zone
        }
        return lhs.recordName < rhs.recordName
    }
}

public enum CloudPrivateZone: Hashable, Codable, Sendable {
    case `default`
    case custom(CloudZoneIdentifier)
}

public enum CloudSharedZone: Hashable, Codable, Sendable {
    case custom(CloudZoneIdentifier)
}

public enum CloudStoreLocation: Hashable, Codable, Sendable {
    case publicDatabase
    case privateDatabase(CloudPrivateZone)
    case sharedDatabase(CloudSharedZone)
}

public struct CloudStoreConfiguration: Hashable, Codable, Sendable {
    public let containerIdentifier: CloudContainerIdentifier
    public let location: CloudStoreLocation

    public init(
        containerIdentifier: CloudContainerIdentifier,
        location: CloudStoreLocation
    ) {
        self.containerIdentifier = containerIdentifier
        self.location = location
    }

    /// CloudKit atomic batches require a custom record zone. Public and
    /// private default zones accept the same modify request but ignore its
    /// atomic flag, so callers must be prepared for per-record outcomes there.
    public var supportsAtomicWrites: Bool {
        switch location {
        case .publicDatabase, .privateDatabase(.default):
            false
        case .privateDatabase(.custom), .sharedDatabase(.custom):
            true
        }
    }
}
