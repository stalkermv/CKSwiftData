# Legacy BackingData layer

Understand the compatibility layer behind macro-generated models.

## Overview

The ``BackingData`` protocol and its record-backed implementation predate the
typed runtime. Macro-generated `@CloudModel` declarations still reference them,
so they remain part of the module, but they are not the foundation of the
typed runtime and are kept for compatibility.

New code should use ``CloudModelContainer`` and ``CloudModelContext`` instead of
calling `CKDatabase` helpers or reading `BackingData` directly.

## What to expect

- The legacy layer stops with a descriptive precondition message on a type
  mismatch rather than returning wrong data.
- It does not provide the conflict handling, partial outcomes, or retry
  behavior of the typed runtime.
- The `CKDatabase` convenience helpers (`save(_:)`, `delete(_:)`, and
  `records(of:matching:)`) belong to this layer.

The layer will be removed or hardened only after the typed runtime meets the
criteria listed in the repository's API contract.
