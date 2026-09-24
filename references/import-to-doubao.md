# Import Prepared Assets into Doubao

Use this finalization workflow only when the user asks to import, migrate, or
sync prepared WorkBuddy or QwenWork content into Doubao. Do not use it for a
local-only export or package request.

The required importer is the plugin named exactly:

```text
AI资产导入豆包
```

Complete Plugin Preflight, Device Identity, and Session Cursor Preflight before
running content-specific workflows. Do not execute Plugin Operation until
every requested content-specific workflow has completed for the source.

## Plugin Preflight

Before creating packages, uploading files, or modifying JSONL for an import
flow, check whether the active Doubao client exposes the plugin named exactly
`AI资产导入豆包`.

If the plugin is not found or is not installed:

1. Tell the user: `请先安装【AI资产导入豆包】插件后重试。`
2. Abort the entire import immediately.
3. Do not continue with any selected source.
4. Do not create new ZIP or JSONL files, upload files, or modify existing
   packages.
5. Do not substitute another plugin or import mechanism.

## Device Identity

Before calling a plugin tool, use the active Doubao client context to resolve
the current installation's local device configuration and its `Local State`.
Do not hardcode an operating-system path, profile path, or JSON field path.

Parse the resolved configuration as structured data and obtain the current
device's `pc_uuid`. Require it to be a non-empty string. If the active context
does not identify one unambiguous configuration and value, stop before calling
the plugin rather than guessing or scanning unrelated client data.

Do not print or persist `pc_uuid` outside the plugin request.

## Import Identifiers

Use these exact source product identifiers:

- WorkBuddy: `source_product: 105`
- QwenWork (千问办公): `source_product: 106`

Use these exact asset type identifiers:

- Skills: `1`
- MCP servers: `2`
- Handbooks: `3`
- Memories, including experiences and user preferences: `4`
- Projects: `5`
- Sessions: `6`

### Session Cursor Preflight

For each selected session source, call `doubao_get_import_config` before
creating or replacing the session package:

```json
{"pc_uuid":"<resolved-pc_uuid>"}
```

From the result, select the single `products` entry whose `source_product`
matches the selected source, then select the single `asset_cursors` entry whose
`asset_type` is `6`:

```json
{
  "products": [
    {
      "source_product": 105,
      "asset_cursors": [
        {"asset_type": 6, "next_cursor": 1789468860000}
      ]
    }
  ]
}
```

- Retrieve the cursor before creating or replacing a session JSONL file.
- Require `next_cursor` to be an integer Unix timestamp in milliseconds.
- Use that value only as the exclusive lower bound for incremental export.
- Never use a cursor from a different `source_product` or `asset_type`.
- Do not infer a cursor from local file timestamps, existing JSONL files, or
  the current time.
- If no cursor is returned for the matching `source_product` and `asset_type`,
  perform a full export for that asset type.
- If lookup fails, returns an invalid timestamp, or returns duplicate matching
  entries, abort that source's session import before export.

Cursor lookup is a preflight operation, not an import operation. It does not
replace the final plugin invocation for the validated session file.

After a non-empty incremental export, take the `next_cursor` reported by the
exporter. It must equal the greatest session start timestamp in the exported
batch and must be strictly greater than the retrieved lower bound. Construct
the final cursor object from this new value:

```json
{"asset_type":6,"next_cursor":1789472460000}
```

This new object, not the object returned by `doubao_get_import_config`, advances
the server-side cursor for the next import.

After a non-empty full export caused by a missing cursor, use the same rule:
the new cursor is the greatest session start timestamp in the full exported
batch. There is no lower-bound comparison in this case.

## Prerequisites

For each selected source, validate every requested import file independently.

For an extensible asset package:

1. The source-specific JSONL package exists:
   - WorkBuddy: `workbuddy-import.jsonl`
   - QwenWork: `qwenwork-import.jsonl`
2. Every physical line is valid JSON and follows the shared JSONL contract.
3. Every requested handbook, memory, MCP, or other structured asset is already
   represented in the JSONL package.
4. Every requested skill ZIP has passed archive and layout validation.
5. Every skill ZIP has been uploaded through the Doubao client cloud upload
   capability.
6. Every `skill` record contains the exact non-empty returned `zip_url`.

For a standalone session package:

1. The source-specific session JSONL file exists:
   - WorkBuddy: `workbuddy-sessions.jsonl`
   - QwenWork: `qwenwork-sessions.jsonl`
2. The package was generated incrementally from the matching cursor returned
   by `doubao_get_import_config`, or as a full export because no matching
   cursor was returned.
3. Every physical line is valid JSON and follows the standalone session schema
   in `references/import-sessions.md`.
4. The package contains sessions from exactly one source.

No selected import file may contain a placeholder, unresolved conflict, failed
content workflow, or temporary record.

If any prerequisite fails, stop before invoking the plugin and report the
source, import file, and failed prerequisite.

## Plugin Operation

Upload each validated JSONL file through the Doubao client cloud upload
capability and retain its exact returned URL:

1. Put the extensible asset package URL in `asset_url`. Use an empty string
   when that source has no extensible asset package.
2. Put session package URLs in `session_url_list`. Use an empty array when that
   source has no session package.
3. Set `source_product` from the exact mapping above.
4. Set `asset_types` to exactly the requested types from the mapping above.
   Include `5` when the uploaded asset package contains project records and
   include `6` when sessions are included.
5. Set `pc_uuid` to the value resolved from the active Doubao context.
6. For session imports, set `next_asset_cursors` to an array containing
   `asset_type: 6` and the new cursor reported by the completed incremental
   export. Otherwise use an empty array.

A combined WorkBuddy request containing every defined asset type has this
shape:

```json
{
  "source_product": 105,
  "asset_types": [1, 2, 3, 4, 5, 6],
  "asset_url": "<uploaded-workbuddy-import-jsonl-url>",
  "session_url_list": ["<uploaded-workbuddy-sessions-jsonl-url>"],
  "pc_uuid": "<resolved-pc-uuid>",
  "next_asset_cursors": [
    {"asset_type": 6, "next_cursor": 1789472460000}
  ]
}
```

Invoke the import tool exposed by `AI资产导入豆包` once per selected source with
this request. Do not paste, summarize, or reconstruct JSONL contents in the
request. Do not merge the asset and session files; pass their uploaded URLs
through their separate fields.

Wait for the structured completion result and treat the source as imported
only when the plugin explicitly reports success. If one source succeeds and
another fails, report the partial result accurately. Do not retry
automatically unless the plugin explicitly indicates that retry is safe.

## Availability

Use only the plugin capability exposed in the active Doubao client context. Do
not guess plugin parameters that the client does not expose.

If `AI资产导入豆包` is not found or is not installed, use the installation
prompt and abort behavior from Plugin Preflight.

If the installed plugin is disabled, disconnected, or requires user
interaction, stop the entire import and report the exact blocking state. Do
not replace it with:

- local Doubao profile writes
- shell-based copying
- guessed HTTP endpoints
- `curl`, `WebFetch`, or browser automation
- another similarly named plugin

## Safety

- Never invoke the plugin for local-only export requests.
- Never invoke the plugin before the selected import file has passed its
  content-specific validation.
- Never send an empty placeholder in `session_url_list`.
- Never reuse the retrieved lower-bound cursor as the new cursor after a
  non-empty export.
- Never derive the new cursor from the current time or local file timestamps.
- Never pass a ZIP directly to this plugin when the workflow requires its URL
  inside a `skill` JSONL record.
- Never claim import success without an explicit plugin success result.
- Never delete local ZIP or JSONL packages after import.
- Never print handbook content, memories, MCP URLs, or skill upload URLs.
