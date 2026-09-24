---
name: "migrate-doubao-assets"
description: "Exports assets from supported assistants and prepares compatible assets for Doubao import. Invoke for exporting, packaging, importing, syncing, or migrating assistant data."
---

# Prepare Doubao Import Packages

Use this skill as the routing entry point for exporting or packaging content
from supported assistant products, including WorkBuddy and QwenWork (千问办公),
and for importing compatible assets into Doubao.

Identify the requested content type before loading a content-specific workflow.
Do not assume that every import request is about skills.

## Workflow Routing

- Skills: When the user explicitly asks to import, export, package, sync, or
  migrate skills, read `references/import-skills.md` completely and follow it.
- Handbooks: When the user explicitly asks to import or export a handbook,
  work manual, custom prompt, `customPrompt`, or `AGENTS.md`, read
  `references/import-handbooks.md` completely and follow it.
- Memories: When the user explicitly asks to import, export, package, sync, or
  migrate memories, experiences, user preferences, `MEMORY.md`, `SOUL.md`, or
  `USER.md`, read `references/import-memories.md` completely and follow it.
- MCP servers: When the user explicitly asks to import or export MCP server
  configurations, read `references/import-mcp.md` completely and follow it.
- Sessions: When the user asks to find, inspect, export, archive, package,
  import, sync, or migrate session history from any assistant product, read
  `references/import-sessions.md` completely and follow its source adapter,
  package, and import rules.
- Unspecified content: When the user asks to import or export content without
  naming its type, ask which content type they want. Do not load a
  content-specific reference until the type is known.
- Mixed content: Load only the reference files for the content types requested.
  Build one fresh per-source staging package for the current request and apply
  each selected structured-asset workflow to it. Never use a completed package
  from an earlier request as the staging input.
- Unsupported content: If no reference exists for the requested content type,
  report that the workflow is not yet defined. Do not reuse the skill workflow
  for another content type.

Keep content-specific discovery paths, eligibility rules, package layouts,
commands, and validation procedures in their reference files. Do not duplicate
those rules in this routing file.

## Available Workflows

- Skill import packages: `references/import-skills.md`
- Handbook import packages: `references/import-handbooks.md`
- Memory import packages (experiences and user preferences):
  `references/import-memories.md`
- WorkBuddy and QwenWork MCP import packages: `references/import-mcp.md`
- Session import packages: `references/import-sessions.md`
- Final Doubao plugin import: `references/import-to-doubao.md`

## Shared Contracts

- Extensible structured-data packages:
  `references/jsonl-package-format.md`
- Load a shared contract only when the selected content-specific workflow
  requires it.

## Import Finalization

When the user requests import, migration, or sync into Doubao for a content
type with a defined import package:

1. Read `references/import-to-doubao.md` completely.
2. Run its plugin preflight before creating packages, uploading files, or
   modifying JSONL.
3. If `AI资产导入豆包` is not found, tell the user to install it and abort the
   entire import.
4. Let the active Doubao context resolve `pc_uuid` from its local device
   configuration without assuming a fixed path.
5. For session imports, call `doubao_get_import_config` with `pc_uuid` and
   retrieve the cursor for the selected `source_product` and `asset_type: 6`
   before export. If no matching cursor is returned, perform a full session
   export.
6. Complete every requested content-specific workflow.
7. Complete required skill ZIP cloud uploads and write their `skill` records.
8. Validate and upload each source-specific JSONL package. For a non-empty
   session export, retain the exporter-reported new cursor.
9. Follow the plugin operation in `references/import-to-doubao.md` as the
   final step, using the new session cursor in `next_asset_cursors`.

Invoke the final plugin once per selected source. Keep the source's extensible
asset package and standalone session package as separate files, then pass their
uploaded URLs through `asset_url` and `session_url_list` in the same source
request. Do not run final import for local-only export or package requests.

## Common Boundaries

- Prepare source packages and use the required final plugin for import flows;
  do not write into a local Doubao profile.
- Never modify or delete source content.
- Do not combine different content types unless their workflow explicitly
  requires it.
- Keep session packages standalone and source-specific. Do not add them to an
  extensible asset package.
- Follow the selected reference file's output, conflict, validation, and safety
  rules.
