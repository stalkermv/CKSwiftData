import CKSwiftData
import Foundation
import Testing

struct CloudSchemaInverseTests {
    private func toMany(
        _ name: String,
        to destination: String,
        inverse: String? = nil
    ) throws -> CloudFieldSchema {
        try .relationship(
            CloudRelationshipSchema(
                id: CloudFieldIdentifier(name),
                recordName: CloudFieldIdentifier(name),
                destination: CloudModelIdentifier(destination),
                inverse: inverse.map { try CloudFieldIdentifier($0) },
                cardinality: CloudRelationshipCardinality(ordering: .stable)
            )
        )
    }

    private func toOne(
        _ name: String,
        to destination: String,
        inverse: String? = nil
    ) throws -> CloudFieldSchema {
        try .relationship(
            CloudRelationshipSchema(
                id: CloudFieldIdentifier(name),
                recordName: CloudFieldIdentifier(name),
                destination: CloudModelIdentifier(destination),
                inverse: inverse.map { try CloudFieldIdentifier($0) },
                cardinality: .toOne(required: false)
            )
        )
    }

    private func model(_ name: String, _ fields: [CloudFieldSchema]) throws -> CloudModelSchema {
        let id = try CloudModelIdentifier(name)
        return try CloudModelSchema(id: id, recordType: id, fields: fields)
    }

    private func inverse(
        of field: String,
        in model: String,
        schema: CloudSchema
    ) throws -> CloudFieldIdentifier? {
        let found = try schema.model(CloudModelIdentifier(model))?.field(CloudFieldIdentifier(field))
        guard case let .relationship(relationship) = found else { return nil }
        return relationship.inverse
    }

    @Test
    func inverseDeclaredOnOneSideIsInferredForTheOther() throws {
        let schema = try CloudSchema(models: [
            model("Task", [toOne("project", to: "Project")]),
            model("Project", [toMany("tasks", to: "Task", inverse: "project")])
        ])

        #expect(try inverse(of: "project", in: "Task", schema: schema)?.rawValue == "tasks")
        #expect(try inverse(of: "tasks", in: "Project", schema: schema)?.rawValue == "project")
    }

    @Test
    func inverseOnTheToOneSideIsInferredForTheToManySide() throws {
        let schema = try CloudSchema(models: [
            model("Task", [toOne("project", to: "Project", inverse: "tasks")]),
            model("Project", [toMany("tasks", to: "Task")])
        ])

        #expect(try inverse(of: "tasks", in: "Project", schema: schema)?.rawValue == "project")
    }

    @Test
    func declaringBothSidesStillWorks() throws {
        let schema = try CloudSchema(models: [
            model("Task", [toOne("project", to: "Project", inverse: "tasks")]),
            model("Project", [toMany("tasks", to: "Task", inverse: "project")])
        ])

        #expect(try inverse(of: "project", in: "Task", schema: schema)?.rawValue == "tasks")
        #expect(try inverse(of: "tasks", in: "Project", schema: schema)?.rawValue == "project")
    }

    @Test
    func selfReferencingModelInfersTheParentSide() throws {
        let schema = try CloudSchema(models: [
            model("Folder", [
                toOne("parent", to: "Folder"),
                toMany("children", to: "Folder", inverse: "parent")
            ])
        ])

        #expect(try inverse(of: "parent", in: "Folder", schema: schema)?.rawValue == "children")
    }

    @Test
    func relationshipsWithoutAnyInverseStayWithoutOne() throws {
        let schema = try CloudSchema(models: [
            model("Task", [toOne("project", to: "Project")]),
            model("Project", [toMany("tasks", to: "Task")])
        ])

        #expect(try inverse(of: "project", in: "Task", schema: schema) == nil)
        #expect(try inverse(of: "tasks", in: "Project", schema: schema) == nil)
    }

    @Test
    func inferredInversesSurviveARoundTripThroughTheManifest() throws {
        let schema = try CloudSchema(models: [
            model("Task", [toOne("project", to: "Project")]),
            model("Project", [toMany("tasks", to: "Task", inverse: "project")])
        ])

        let decoded = try JSONDecoder().decode(CloudSchema.self, from: JSONEncoder().encode(schema))
        #expect(decoded == schema)
    }

    @Test
    func twoRelationshipsNamingTheSameInverseAreAmbiguous() throws {
        let task = try CloudModelIdentifier("Task")
        let project = try CloudFieldIdentifier("project")
        do {
            _ = try CloudSchema(models: [
                model("Task", [toOne("project", to: "Project")]),
                model("Project", [
                    toMany("tasks", to: "Task", inverse: "project"),
                    toMany("archived", to: "Task", inverse: "project")
                ])
            ])
            Issue.record("Two relationships naming the same inverse must be rejected")
        } catch let error as CloudSchemaError {
            #expect(error == .ambiguousInverse(task, project))
        }
    }

    @Test
    func inverseNamingAMissingFieldIsRejected() throws {
        let projectModel = try CloudModelIdentifier("Project")
        let tasks = try CloudFieldIdentifier("tasks")
        let projct = try CloudFieldIdentifier("projct")
        do {
            _ = try CloudSchema(models: [
                model("Task", [toOne("project", to: "Project")]),
                model("Project", [toMany("tasks", to: "Task", inverse: "projct")])
            ])
            Issue.record("An unknown inverse field must be rejected")
        } catch let error as CloudSchemaError {
            #expect(error == .unknownInverse(projectModel, tasks, projct))
        }
    }

    @Test
    func inverseNamingAnAttributeIsRejected() throws {
        let projectModel = try CloudModelIdentifier("Project")
        let taskModel = try CloudModelIdentifier("Task")
        let tasks = try CloudFieldIdentifier("tasks")
        let title = try CloudAttributeSchema(
            id: CloudFieldIdentifier("title"),
            recordName: CloudFieldIdentifier("title"),
            kind: .scalar
        )
        do {
            _ = try CloudSchema(models: [
                model("Task", [.attribute(title)]),
                model("Project", [toMany("tasks", to: "Task", inverse: "title")])
            ])
            Issue.record("An attribute cannot be an inverse")
        } catch let error as CloudSchemaError {
            #expect(error == .inverseMismatch(projectModel, tasks, taskModel))
        }
    }

    @Test
    func inverseOnARelationshipToAnotherModelIsRejected() throws {
        let projectModel = try CloudModelIdentifier("Project")
        let taskModel = try CloudModelIdentifier("Task")
        let tasks = try CloudFieldIdentifier("tasks")
        do {
            _ = try CloudSchema(models: [
                model("Task", [toOne("owner", to: "Person")]),
                model("Person", []),
                model("Project", [toMany("tasks", to: "Task", inverse: "owner")])
            ])
            Issue.record("An inverse must point back at the declaring model")
        } catch let error as CloudSchemaError {
            #expect(error == .inverseMismatch(projectModel, tasks, taskModel))
        }
    }

    @Test
    func inverseContradictingTheOtherSideIsRejected() throws {
        let projectModel = try CloudModelIdentifier("Project")
        let taskModel = try CloudModelIdentifier("Task")
        let tasks = try CloudFieldIdentifier("tasks")
        do {
            _ = try CloudSchema(models: [
                model("Task", [toOne("project", to: "Project", inverse: "archived")]),
                model("Project", [
                    toMany("tasks", to: "Task", inverse: "project"),
                    toMany("archived", to: "Task")
                ])
            ])
            Issue.record("Contradicting inverses must be rejected")
        } catch let error as CloudSchemaError {
            #expect(error == .inverseMismatch(projectModel, tasks, taskModel))
        }
    }
}
