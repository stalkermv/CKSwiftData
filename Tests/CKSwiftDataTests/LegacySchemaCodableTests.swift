import CKSwiftData
import Foundation
import Testing

struct LegacySchemaCodableTests {
    @Test
    func attributeCodablePreservesStableMetadataAndMakesRuntimeLossExplicit() throws {
        let attribute = Schema.Attribute(
            name: "title",
            originalName: "name",
            options: [.unique, .allowsCloudEncryption],
            valueType: String.self,
            defaultValue: "Untitled",
            hashModifier: "v2"
        )

        let data = try JSONEncoder().encode(attribute)
        let decoded = try JSONDecoder().decode(Schema.Attribute.self, from: data)

        #expect(decoded.name == "title")
        #expect(decoded.originalName == "name")
        #expect(decoded.options == attribute.options)
        #expect(decoded.isOptional)
        #expect(decoded.hashModifier == "v2")
        #expect(decoded.defaultValue == nil)
        #expect(String(describing: decoded.valueType) == "Any")
    }
}
