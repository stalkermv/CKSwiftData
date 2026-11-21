import CKSwiftData
import Testing

struct CloudRelationshipGraphTests {
    @Test
    func plannerProducesDeterministicEdgeUpsertsAndDeletes() throws {
        let zone = try CloudZoneIdentifier("private")
        let source = try CloudRecordIdentifier(recordName: "source", zone: zone)
        let oldTarget = try CloudRecordIdentifier(recordName: "old", zone: zone)
        let newTarget = try CloudRecordIdentifier(recordName: "new", zone: zone)
        let relationship = try CloudFieldIdentifier("children")
        let edgeModel = try CloudModelIdentifier("RelationshipEdge")
        let sourceField = try CloudFieldIdentifier("source")
        let relationshipField = try CloudFieldIdentifier("relationship")
        let targetField = try CloudFieldIdentifier("target")
        let positionField = try CloudFieldIdentifier("position")
        let planner = CloudRelationshipGraphPlanner(
            edgeModelID: edgeModel,
            sourceField: sourceField,
            relationshipField: relationshipField,
            targetField: targetField,
            positionField: positionField
        )
        let change = try CloudRelationshipChange(
            source: source,
            relationship: relationship,
            oldTargets: [oldTarget],
            newTargets: [newTarget],
            ordering: .stable
        )

        let plan = try planner.plan(change)
        #expect(plan.saving.count == 1)
        #expect(plan.deletingEdges.count == 1)
        #expect(plan.saving[0].values[sourceField] == .reference(source))
        #expect(plan.saving[0].values[targetField] == .reference(newTarget))
        #expect(plan.saving[0].values[positionField] == .int64(0))
        #expect(plan.deletingRecords.isEmpty)

        let edge = try CloudRelationshipEdge(
            source: source,
            relationship: relationship,
            target: newTarget,
            position: 0
        )
        let expectedEdgeID = try edge.recordID(edgeModelID: edgeModel)
        #expect(plan.saving[0].id == expectedEdgeID)
    }

    @Test
    func deleteRulesAreExplicitAndCrossZoneEdgesAreRejected() throws {
        let privateZone = try CloudZoneIdentifier("private")
        let source = try CloudRecordIdentifier(recordName: "source", zone: privateZone)
        let target = try CloudRecordIdentifier(recordName: "target", zone: privateZone)
        let relationship = try CloudFieldIdentifier("children")
        let planner = try CloudRelationshipGraphPlanner(
            edgeModelID: CloudModelIdentifier("RelationshipEdge"),
            sourceField: CloudFieldIdentifier("source"),
            relationshipField: CloudFieldIdentifier("relationship"),
            targetField: CloudFieldIdentifier("target")
        )

        let cascade = try planner.planDelete(
            source: source,
            relationship: relationship,
            targets: [target],
            deleteRule: .cascade
        )
        #expect(cascade.deletingRecords == [target])

        do {
            _ = try planner.planDelete(
                source: source,
                relationship: relationship,
                targets: [target],
                deleteRule: .deny
            )
            Issue.record("deny must reject a non-empty relationship")
        } catch let error as CloudRelationshipGraphError {
            #expect(error == .denyDelete(source, relationship))
        }

        do {
            _ = try CloudRelationshipChange(
                source: source,
                relationship: relationship,
                oldTargets: [],
                newTargets: [CloudRecordIdentifier(
                    recordName: "other",
                    zone: CloudZoneIdentifier("shared")
                )]
            )
            Issue.record("cross-zone edges must be rejected")
        } catch let error as CloudRelationshipGraphError {
            #expect(error != .denyDelete(source, relationship))
        }
    }

    @Test
    func edgeReaderFiltersAndOrdersCanonicalRecords() async throws {
        let zone = try CloudZoneIdentifier("private")
        let source = try CloudRecordIdentifier(recordName: "source", zone: zone)
        let targetA = try CloudRecordIdentifier(recordName: "a", zone: zone)
        let targetB = try CloudRecordIdentifier(recordName: "b", zone: zone)
        let relationship = try CloudFieldIdentifier("children")
        let edgeModel = try CloudModelIdentifier("RelationshipEdge")
        let sourceField = try CloudFieldIdentifier("source")
        let relationshipField = try CloudFieldIdentifier("relationship")
        let targetField = try CloudFieldIdentifier("target")
        let positionField = try CloudFieldIdentifier("position")
        let planner = CloudRelationshipGraphPlanner(
            edgeModelID: edgeModel,
            sourceField: sourceField,
            relationshipField: relationshipField,
            targetField: targetField,
            positionField: positionField
        )
        let plan = try planner.plan(
            CloudRelationshipChange(
                source: source,
                relationship: relationship,
                oldTargets: [],
                newTargets: [targetB, targetA],
                ordering: .stable
            )
        )
        let attributeFields: [CloudFieldSchema] = try [sourceField, relationshipField, targetField, positionField].map {
            try .attribute(CloudAttributeSchema(
                id: $0,
                recordName: $0,
                kind: .scalar
            ))
        }
        let schema = try CloudSchema(models: [
            CloudModelSchema(id: edgeModel, recordType: edgeModel, fields: attributeFields)
        ])
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient()
        let store = try CloudKitRecordStore(
            schema: schema,
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.Tests"),
                location: .privateDatabase(.custom(zone))
            ),
            client: client
        )
        _ = try await store.apply(plan)
        let reader = CloudRelationshipEdgeReader(
            store: store,
            edgeModelID: edgeModel,
            sourceField: sourceField,
            relationshipField: relationshipField,
            targetField: targetField,
            positionField: positionField
        )
        let page = try await reader.fetch(
            CloudRelationshipEdgeQuery(
                source: source,
                relationship: relationship,
                limit: 10
            )
        )
        #expect(page.edges.map(\.target) == [targetB, targetA])
        #expect(page.nextCursor == nil)
    }

    @Test
    func edgeReaderDoesNotSkipFilteredRecordsAcrossPages() async throws {
        let zone = try CloudZoneIdentifier("private")
        let source = try CloudRecordIdentifier(recordName: "source", zone: zone)
        let otherSource = try CloudRecordIdentifier(recordName: "other", zone: zone)
        let targets = try ["target-1", "target-2", "target-3"].map {
            try CloudRecordIdentifier(recordName: $0, zone: zone)
        }
        let relationship = try CloudFieldIdentifier("children")
        let edgeModel = try CloudModelIdentifier("RelationshipEdge")
        let sourceField = try CloudFieldIdentifier("source")
        let relationshipField = try CloudFieldIdentifier("relationship")
        let targetField = try CloudFieldIdentifier("target")
        let positionField = try CloudFieldIdentifier("position")
        let recordNames = try ["a", "b", "c", "d"].map {
            try CloudRecordIdentifier(recordName: $0, zone: zone)
        }
        let snapshots = try recordNames.enumerated().map { index, id in
            let isMatch = index > 0
            let target = targets[min(max(index - 1, 0), targets.count - 1)]
            return try CloudRecordSnapshot(
                id: id,
                modelID: edgeModel,
                changeTag: "c\(index + 1)",
                fields: [
                    sourceField: .reference(isMatch ? source : otherSource),
                    relationshipField: .string(relationship.rawValue),
                    targetField: .reference(target),
                    positionField: .int64(Int64(max(index - 1, 0)))
                ]
            )
        }
        let fields: [CloudFieldSchema] = try [sourceField, relationshipField, targetField, positionField].map {
            try .attribute(CloudAttributeSchema(id: $0, recordName: $0, kind: .scalar))
        }
        let schema = try CloudSchema(models: [
            CloudModelSchema(id: edgeModel, recordType: edgeModel, fields: fields)
        ])
        let client = try CKSwiftDataTesting.InMemoryCloudDatabaseClient(initial: snapshots)
        let store = try CloudKitRecordStore(
            schema: schema,
            configuration: CloudStoreConfiguration(
                containerIdentifier: CloudContainerIdentifier("iCloud.example.EdgePaging"),
                location: .privateDatabase(.custom(zone))
            ),
            client: client
        )
        let reader = CloudRelationshipEdgeReader(
            store: store,
            edgeModelID: edgeModel,
            sourceField: sourceField,
            relationshipField: relationshipField,
            targetField: targetField,
            positionField: positionField
        )
        let query = try CloudRelationshipEdgeQuery(
            source: source,
            relationship: relationship,
            limit: 2
        )

        let first = try await reader.fetch(query)
        #expect(first.edges.map(\.target) == Array(targets.prefix(2)))
        let next = try #require(first.nextCursor)
        do {
            _ = try await reader.fetch(
                CloudRelationshipEdgeQuery(
                    source: otherSource,
                    relationship: relationship,
                    limit: 2,
                    cursor: next
                )
            )
            Issue.record("An edge cursor must not be reusable for another source")
        } catch let error as CloudModelError {
            #expect(error == .invalidRequest(
                "relationship edge cursor scope does not match query"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let second = try await reader.fetch(
            CloudRelationshipEdgeQuery(
                source: source,
                relationship: relationship,
                limit: 2,
                cursor: next
            )
        )
        #expect(second.edges.map(\.target) == [targets[2]])
        #expect(second.nextCursor == nil)
    }
}
