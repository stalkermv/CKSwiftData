import CKSwiftData
import Foundation
import Testing

struct CloudIdentityTests {
    @Test
    func identifiersTrimWhitespaceAndRemainStable() throws {
        let model = try CloudModelIdentifier("  Project  ")
        let field = try CloudFieldIdentifier("title")
        let zone = try CloudZoneIdentifier("AppData")
        let record = try CloudRecordIdentifier(recordName: "project-1", zone: zone)

        #expect(model.rawValue == "Project")
        #expect(field.description == "title")
        #expect(record.recordName == "project-1")
        #expect(record.zone == zone)
    }

    @Test
    func identifiersSortByTheirCanonicalComponents() throws {
        let alpha = try CloudZoneIdentifier("Alpha")
        let beta = try CloudZoneIdentifier("Beta")
        let first = try CloudRecordIdentifier(recordName: "first", zone: alpha)
        let second = try CloudRecordIdentifier(recordName: "second", zone: alpha)
        let crossZone = try CloudRecordIdentifier(recordName: "aaa", zone: beta)

        #expect([second, first, crossZone].sorted() == [first, second, crossZone])
        #expect(try [
            CloudModelIdentifier("Beta"),
            CloudModelIdentifier("Alpha")
        ].sorted().map(\.rawValue) == ["Alpha", "Beta"])
        #expect(try [
            CloudFieldIdentifier("zeta"),
            CloudFieldIdentifier("alpha")
        ].sorted().map(\.rawValue) == ["alpha", "zeta"])
        #expect([beta, alpha].sorted() == [alpha, beta])
    }

    @Test
    func invalidIdentifiersAreRejected() {
        do {
            _ = try CloudModelIdentifier(" ")
            Issue.record("An empty model identifier must be rejected")
        } catch let error as CloudIdentityError {
            #expect(error == .empty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            _ = try CloudFieldIdentifier("title/name")
            Issue.record("Invalid identifier characters must be rejected")
        } catch let error as CloudIdentityError {
            #expect(error == .invalidCharacters("title/name"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func codableIdentifiersAndCursorsReapplyConstructionInvariants() throws {
        let decoder = JSONDecoder()

        do {
            _ = try decoder.decode(
                CloudModelIdentifier.self,
                from: Data(#"{"rawValue":"bad/name"}"#.utf8)
            )
            Issue.record("Decoded model identifiers must use the same key validator")
        } catch let error as CloudIdentityError {
            #expect(error == .invalidCharacters("bad/name"))
        }

        do {
            _ = try decoder.decode(
                CloudPageCursor.self,
                from: Data(#"{"rawValue":"   "}"#.utf8)
            )
            Issue.record("Decoded cursors must not be empty")
        } catch let error as CloudRecordBoundaryError {
            #expect(error == .emptyCursor)
        }
    }

    @Test
    func containerIdentifierRequiresICloudPrefix() {
        do {
            _ = try CloudContainerIdentifier("com.example.App")
            Issue.record("A CloudKit container identifier must use the iCloud prefix")
        } catch let error as CloudIdentityError {
            #expect(error == .invalidContainerIdentifier("com.example.App"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func storeLocationsEncodeOnlyLegalScopes() throws {
        let identifier = try CloudContainerIdentifier("iCloud.com.example.App")
        let configuration = try CloudStoreConfiguration(
            containerIdentifier: identifier,
            location: .privateDatabase(.custom(CloudZoneIdentifier("AppData")))
        )

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(CloudStoreConfiguration.self, from: data)
        #expect(decoded == configuration)
    }

    @Test
    func atomicWriteCapabilityMatchesCloudKitZoneScope() throws {
        let container = try CloudContainerIdentifier("iCloud.com.example.App")
        let custom = try CloudStoreConfiguration(
            containerIdentifier: container,
            location: .privateDatabase(.custom(CloudZoneIdentifier("AppData")))
        )
        let defaultZone = CloudStoreConfiguration(
            containerIdentifier: container,
            location: .privateDatabase(.default)
        )
        let publicDatabase = CloudStoreConfiguration(
            containerIdentifier: container,
            location: .publicDatabase
        )

        #expect(custom.supportsAtomicWrites)
        #expect(defaultZone.supportsAtomicWrites == false)
        #expect(publicDatabase.supportsAtomicWrites == false)
    }
}
