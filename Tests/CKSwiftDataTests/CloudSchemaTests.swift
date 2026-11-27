import CKSwiftData
import Testing

struct CloudSchemaTests {
    @Test
    func schemaSortsDeterministicallyAndValidatesInverses() throws {
        let projectID = try CloudModelIdentifier("Project")
        let taskID = try CloudModelIdentifier("Task")
        let tasksID = try CloudFieldIdentifier("tasks")
        let projectFieldID = try CloudFieldIdentifier("project")

        let projectTasks = try CloudRelationshipSchema(
            id: tasksID,
            recordName: CloudFieldIdentifier("task_edges"),
            destination: taskID,
            inverse: projectFieldID,
            cardinality: CloudRelationshipCardinality(ordering: .stable),
            deleteRule: .cascade
        )
        let taskProject = try CloudRelationshipSchema(
            id: projectFieldID,
            recordName: CloudFieldIdentifier("project_ref"),
            destination: projectID,
            inverse: tasksID,
            cardinality: .toOne(required: false)
        )

        let project = try CloudModelSchema(
            id: projectID,
            recordType: projectID,
            fields: [.relationship(projectTasks)]
        )
        let task = try CloudModelSchema(
            id: taskID,
            recordType: taskID,
            fields: [.relationship(taskProject)]
        )
        let schema = try CloudSchema(models: [task, project])

        #expect(schema.models.map(\.id.rawValue) == ["Project", "Task"])
        #expect(schema.model(projectID)?.field(tasksID) == .relationship(projectTasks))
    }

    @Test
    func duplicateFieldsAreRejected() throws {
        let modelID = try CloudModelIdentifier("Project")
        let fieldID = try CloudFieldIdentifier("title")
        let first = try CloudAttributeSchema(
            id: fieldID,
            recordName: CloudFieldIdentifier("title"),
            kind: .scalar
        )
        let second = try CloudAttributeSchema(
            id: fieldID,
            recordName: CloudFieldIdentifier("title_copy"),
            kind: .scalar
        )

        do {
            _ = try CloudModelSchema(
                id: modelID,
                recordType: modelID,
                fields: [.attribute(first), .attribute(second)]
            )
            Issue.record("Duplicate field IDs must be rejected")
        } catch let error as CloudSchemaError {
            #expect(error == .duplicateFieldIdentifier(modelID, fieldID))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func unknownRelationshipDestinationIsRejected() throws {
        let sourceID = try CloudModelIdentifier("Project")
        let destinationID = try CloudModelIdentifier("Missing")
        let relationID = try CloudFieldIdentifier("missing")
        let relation = CloudRelationshipSchema(
            id: relationID,
            recordName: relationID,
            destination: destinationID,
            cardinality: .toOne(required: false)
        )
        let source = try CloudModelSchema(
            id: sourceID,
            recordType: sourceID,
            fields: [.relationship(relation)]
        )

        do {
            _ = try CloudSchema(models: [source])
            Issue.record("Unknown relationship destinations must be rejected")
        } catch let error as CloudSchemaError {
            #expect(error == .unknownRelationshipDestination(sourceID, relationID, destinationID))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func schemaRoundTripRunsValidationOnDecode() throws {
        let modelID = try CloudModelIdentifier("Project")
        let fieldID = try CloudFieldIdentifier("title")
        let attribute = try CloudAttributeSchema(
            id: fieldID,
            recordName: fieldID,
            kind: .scalar,
            optionality: .optional
        )
        let model = try CloudModelSchema(
            id: modelID,
            recordType: modelID,
            version: 2,
            fields: [.attribute(attribute)]
        )
        let schema = try CloudSchema(version: 2, models: [model])
        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(CloudSchema.self, from: data)

        #expect(decoded == schema)
        #expect(decoded.version == 2)
    }
}
