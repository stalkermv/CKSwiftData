# Relationships and Migrations

Plan relationship edges and schema changes explicitly.

## Relationship edges

To-many relationships use canonical edge records with a deterministic identity
for each `(source, relationship, target)` triple. That prevents duplicates and
allows bounded pagination and many-to-many relationships.

- ``CloudRelationshipGraphPlanner`` computes the old and new relationship
  collections into a cycle-safe persistence plan.
- ``CloudRelationshipEdgeReader`` reads edge pages for a source and
  relationship.
- ``CloudDeleteRule`` values are enforced by explicit planner operations.
  `CloudModelContext.delete` does not silently apply a graph plan.

Edge pages are filtered client-side and sorted within each remote prefix. A
globally stable order across pages is not guaranteed. Edge records the store
could not read are listed in ``CloudRelationshipEdgePage/failures``; a page with
failures may be missing relationships.

## Migrations

CloudKit production schema changes are coordinated through a checked-in schema
manifest and an operator deployment step. The library provides:

- ``CloudMigrationPlan`` with additive fields, rename aliases, required-field
  backfill stages, and verification stages.
- ``CloudMigrationCoordinator``, an actor that runs a plan and persists
  checkpoints through a ``CloudMigrationCheckpointStore``.
- ``CloudMigrationStageExecutor``, which you implement for application-specific
  transforms and backfills.

A rename copies values from one attribute to another, so the planner accepts
it only between attributes with the same kind, value kind, optionality, and
storage options, from a field the new schema no longer declares, and with one
destination per source. The coordinator trusts a completed checkpoint only when
it covers every stage of the plan.

Destructive production field deletion is outside the library's automatic
scope.
