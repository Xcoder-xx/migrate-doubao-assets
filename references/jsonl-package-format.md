# Shared JSONL Package Format

Use this contract when a content-specific workflow writes structured import
data for later upload to Doubao.

Create one extensible JSONL package per selected source:

- WorkBuddy: `workbuddy-import.jsonl`
- QwenWork: `qwenwork-import.jsonl`

Each physical line must contain exactly one compact JSON object. Every object
must contain a non-empty string `item_type` that identifies the imported
content type. Embedded line breaks must be escaped inside JSON strings and
must not create additional physical lines.

Terminate every record with LF (`\n`), including the final record. Write UTF-8
without a byte-order mark.

## Package Lifetime

Each export request builds a new source package from exactly the asset types
selected in that request. Never seed a new request from a package completed by
an earlier request, even when both use the same final filename.

For a mixed-content request, create one fresh staging package and let each
selected workflow add its records to that staging package. Records already
written by another workflow in the same request are retained. After every
selected workflow succeeds, validate the complete staging package and
atomically replace the final source package. Replacing an existing final file
still requires explicit overwrite approval.

This means a later session-only export does not inherit memory records from an
earlier memory export, while one request that selects both memory and sessions
retains both memory and project records.

## Existing Packages

An in-progress staging package may contain records written by other workflows
selected in the same request. Before changing it:

1. Decode the complete file as UTF-8.
2. Parse every non-final physical line as one JSON object.
3. Reject blank lines, invalid JSON, non-object values, and records without a
   non-empty string `item_type`.
4. Preserve records belonging to other `item_type` values.

Each content-specific workflow must declare its item type as either a
singleton or a collection:

- Singleton: The package may contain at most one record with that `item_type`.
  When absent, append the new record. When present, skip it by default and
  replace only that record after explicit overwrite approval. Multiple
  matching records make the package invalid for that workflow.
- Collection: The package may contain multiple records with that `item_type`.
  Treat all matching records as one collection. When absent, append the complete
  source collection. When present, skip the collection by default and replace
  the complete collection only after explicit overwrite approval. Never append
  a partial collection to existing records of the same item type.
- Partitioned collection: A content-specific workflow may define a stable
  discriminator within one collection item type. In that case, apply collection
  conflict and replacement rules only to records with both the matching
  `item_type` and discriminator value. Preserve records in every other
  partition byte-for-byte and in their original order.

Current declarations:

- `agents_md` is a singleton.
- Each source's `project` records are one collection maintained by the session
  exporter. They share `<source>-import.jsonl` with handbooks and other
  extensible asset records, but never appear in `<source>-sessions.jsonl`.

Do not treat the existence of the JSONL file itself as a conflict. Conflicts
are scoped to the singleton item or complete collection identified by
`item_type`.

## Safe Writes

Build the complete candidate JSONL content without changing the destination.
Validate every candidate line and the newly serialized record in memory. Write
the candidate to a sibling temporary file, read it back, and validate it again
before atomically replacing the destination.

If any step fails, remove only the temporary file. Preserve the previous
package unchanged.

## Validation

After writing:

- Parse every physical line independently.
- Confirm every line is a JSON object with a valid `item_type`.
- Confirm the new or replaced singleton or collection exactly matches its
  source content.
- Confirm records for other item types are unchanged.
- For a partitioned collection, confirm records in other partitions are
  unchanged.
- Report the package path and item type without exposing private content.

## Safety

- Never write a JSON array or a multi-line JSON object to a JSONL package.
- Never merge WorkBuddy and QwenWork records into the same package.
- Never discard or rewrite records for unrelated item types.
- Never discard or rewrite records from another collection partition.
- Never append an item when the existing package is invalid.
- Never replace an existing singleton or collection without explicit approval.
- Never leave a temporary or known-invalid package as an upload candidate.
