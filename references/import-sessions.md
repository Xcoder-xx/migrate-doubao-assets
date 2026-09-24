# Import Sessions

Use this workflow when the user asks to find, inspect, export, archive, or
package session history from a supported assistant product, or to import,
sync, or migrate that history into Doubao.

Session data must use a standalone, source-specific JSONL file. Never combine
it with handbooks, memories, skills, MCP configurations, an extensible asset
package, or sessions from another source.

## Source Adapters

Use only an adapter explicitly defined below. Do not guess storage paths or
event schemas for an unsupported source.

### QwenWork

- Product names: QwenWork, 千问办公
- Event streams: `$HOME/.qwenworkcn/projects/**/*.jsonl`
- macOS metadata database:
  `$HOME/Library/Application Support/QwenWorkCN/data/agents.db`
- Windows metadata database: `%APPDATA%\QwenWorkCN\data\agents.db`
- macOS exporter: `scripts/export_sessions_macos.js`
- Windows exporter: `scripts/export_sessions_windows.ps1`
- Default output: `$HOME/Downloads/qwenwork-sessions.jsonl`

QwenWork's `agents.db` is the authoritative source for sessions, titles, and
ordered messages. Its `messages.parts` field separates visible text from
reasoning and tool activity. Raw project JSONL files contain model-only prompt
injections and must not be used as a transcript fallback.

### WorkBuddy

- Product name: WorkBuddy
- Event streams: `$HOME/.workbuddy/projects/**/*.jsonl`
- Metadata database: `$HOME/.workbuddy/workbuddy.db`
- Presented artifact index:
  `$HOME/.workbuddy/artifact-index/<session-id>.json`
- macOS exporter: `scripts/export_sessions_macos.js`
- Windows exporter: `scripts/export_sessions_windows.ps1`
- Default output: `$HOME/Downloads/workbuddy-sessions.jsonl`

WorkBuddy's `workbuddy.db` is the authoritative session index. Each
`sessions.id` selects the correspondingly named project JSONL file, which is
the product's message event store; JSONL files not referenced by a live
database row are not exported. Use the artifact index only for files
explicitly delivered through `PresentFiles`.

Future source support must add matching adapters to the platform-native
exporters, with its own discovery path, parser, filtering rules, tests, and
default `<source>-sessions.jsonl` output. Every adapter must emit the common
standalone session schema defined below.

## Visible Session Rules

The QwenWork adapter applies these structural rules:

- Read sessions and messages from `agents.db`. Order conversations by
  `sub_chats.updated_at` and session ID, while preserving each conversation's
  `messages.sequence`.
- Accept only `user` and `assistant` rows. For user rows, accept `parts`
  entries whose type is `text`. For assistant rows, accept only the `text`
  part whose `id` equals `metadata.finalTextId`; other text parts are progress
  broadcasts. If an assistant row has no matching `finalTextId`, emit no text
  from that row. Exclude all thinking and tool parts from text.
- Remove structured `@[mcp-server:...]`, `@[image:...]`, and `@[file:...]`
  markers from visible text.
- Decode `@[image:base64:<path>]` and read `@[file:external:<path>]` as local
  attachments when the referenced file exists.
- Recover files explicitly delivered by
  `qwenwork_file_present_files` directly from its structured database part.
- Use `metadata.sdkMessageUuid` when available, otherwise the database
  `message_id`, as the attachment identifier.
- Exclude QwenWork's internal memory-reflection prompt only when all of its
  explicit protocol markers are present.
- Prefer the exact title mapped through `sub_chats.session_id` in `agents.db`,
  then fall back to the first visible user message.
- Join `task_run_logs.sub_chat_id` to `sub_chats.id` to identify sessions
  created by scheduled tasks. Group those sessions by `task_run_logs.task_id`
  and expose only the session with the greatest `run_at` for each task.
  Manual and scheduled triggers of the same task belong to the same group.
  Failed runs without a `sub_chat_id` do not represent sessions and are
  ignored.
- Treat a conversation as belonging to a user-created project only when
  `chats.local_project_id` points to a non-deleted `local_projects` row. Use
  that row's `id` as `project_id` and its `name` as the project name.
- Do not export the built-in `chats.project_id` as a user project. Ordinary
  conversations share QwenWork's default internal project and must not receive
  a `project_id` or project record.
- On Windows, read SQLite through the system `winsqlite3.dll`. If an active
  source application prevents read-only shared-memory mapping, query a
  temporary database/WAL snapshot and delete it immediately afterward.
  Fall back to `sqlite3.exe` only when the Windows SQLite API is unavailable.
- Exclude sessions with no visible user message after filtering.
- Preserve message order and the remaining message content.

Do not classify sessions by directory name, working directory, title wording,
or other path heuristics.

The WorkBuddy adapter applies these structural rules:

- Read non-deleted session IDs from `workbuddy.db`, then read only matching
  `.jsonl` files under `$HOME/.workbuddy/projects`.
- Order conversations by `sessions.updated_at`, then session ID.
- Treat only rows with `sessions.is_playground = 0` as project
  conversations. Ordinary playground conversations do not receive a
  `project_id` or project record.
- For project conversations, use the matching JSONL file's immediate parent
  directory name as the project key and export it as `project_id`.
  WorkBuddy generates this key by resolving `sessions.cwd` to its canonical
  path, replacing `/`, `\`, and `:` with `-`, trimming leading and trailing
  hyphens, and collapsing repeated hyphens.
- Set the project name to the basename of `sessions.cwd`. WorkBuddy has no
  persisted project description field, so export an empty description.
- Accept only records whose `type` is `message`.
- Exclude user message records whose top-level `providerData.isMeta` is
  `true`. These are internal notifications such as background-task completion
  messages, not user-authored turns. Do not filter user-authored text by
  matching notification markup alone.
- For user records, accept `input_text` content. Prefer the original user
  input in `content[].providerData.content`; this excludes system context and
  full skill instructions injected for slash commands.
- When `providerData.content` is absent, extract only top-level
  `<user_query>...</user_query>` elements that are not nested inside any other
  tag. Never interpret `<user_query>` examples inside system reminders or
  other context wrappers as user text.
- If no top-level `<user_query>` exists, remove system reminder blocks wherever
  they occur and retain the remaining visible text.
- Extract file attachments directly from `@<absolute-path>` references in
  message text, including quoted `@"<absolute-path>"` references used for
  paths with spaces. Extract image attachments only from `<image_local_path>`.
- Remove exported `<image_local_path>` metadata from visible text. Strip only
  the `@image#<number>:` prefix so the image filename remains visible. Replace
  matching `@<absolute-path>` file references with the referenced basename.
- Convert WorkBuddy `@share-html#<encoded-name>:<url>` markers to standard
  Markdown links with decoded labels. For bare `@share-html:<url>` markers,
  derive the label from the URL filename. Preserve visible text after the
  `.html` URL, while retaining any URL query string or fragment.
- Attach each extracted file to the corresponding message using the source
  message UUID as its attachment identifier. Preserve source attachment order
  and deduplicate identical absolute paths within a message.
- Read the session artifact index and include only existing local files whose
  source tool is `PresentFiles`, owner conversation matches the session, and
  request ID matches the assistant answer's conversation request ID. Do not
  export files merely created or edited during the run.
- For assistant records, accept completed `output_text` content only when the
  record has a top-level `message` field. Completed output records without that
  field are intermediate progress narration, not the final answer.
- Merge adjacent assistant text fragments with one blank line because one
  visible assistant turn may be split by reasoning or tool events.
- Keep the visible text in Markdown. Do not export `show_widget` calls,
  rendered widgets, SVG, HTML charts, or their tool results.
- Prefer `custom_title`, then `title`, from the matching database session row.
  Fall back to the explicit `aiTitle` event and then the first visible user
  message.
- Convert integer millisecond timestamps to UTC ISO 8601 strings.
- Exclude reasoning, function calls, function results, file snapshots,
  provider metadata, and other non-message records.
- Exclude sessions with no visible user message after filtering.
- Preserve user turn order and visible assistant content.

## Discovery

Resolve the skill directory first, then use the operating system's built-in
runtime. Do not require Python, Node.js, or another optional runtime.

On macOS, run the system-provided JavaScript for Automation runtime from zsh.
This requires no optional runtime.

List QwenWork sessions:

```zsh
/usr/bin/osascript -l JavaScript scripts/export_sessions_macos.js -- \
  --source qwenwork list
```

List WorkBuddy sessions:

```zsh
/usr/bin/osascript -l JavaScript scripts/export_sessions_macos.js -- \
  --source workbuddy list
```

Add `--json` after `list` for structured discovery:

```zsh
/usr/bin/osascript -l JavaScript scripts/export_sessions_macos.js -- \
  --source workbuddy list --json
```

On Windows, use Windows PowerShell:

```powershell
powershell -NoProfile -File scripts/export_sessions_windows.ps1 `
  -Source workbuddy -Command list -Json
```

Listing reports only session ID, title, start timestamp, and message count when
those fields are available. It does not print assistant responses or internal
event content.

When the user identifies a session by title, match the exact listed title. If
multiple sessions have the same title, show their session IDs and timestamps
and ask which one to export.

## Incremental Import Cursor

Import, migration, and sync requests must be incremental:

1. Complete the plugin and session cursor preflight in
   `references/import-to-doubao.md`.
2. Let the active Doubao context resolve `pc_uuid` from its local device
   configuration without assuming a fixed filesystem or JSON field path.
3. Call `doubao_get_import_config` with `{"pc_uuid":"<pc_uuid>"}`.
4. Select `source_product: 105` for WorkBuddy or `source_product: 106` for
   QwenWork, then look for its `asset_type: 6` cursor.
5. If the matching cursor exists, export only sessions whose start timestamp
   is strictly later than the returned `next_cursor`.
6. If no matching cursor is returned, export all visible sessions.
7. If the selected incremental or full export contains no sessions, do not
   create or replace a session package and do not invoke the import operation.

The plugin's `next_cursor` must be an integer Unix timestamp in milliseconds.
Pass it unchanged to the exporter as the previous cursor. The comparison is an
exclusive lower bound: `session.startedAt > previous_cursor`.

On macOS, export the increment with:

```zsh
/usr/bin/osascript -l JavaScript scripts/export_sessions_macos.js -- \
  --source "<source>" export \
  --cursor "<plugin-cursor>" --json
```

On Windows:

```powershell
powershell -NoProfile -File scripts/export_sessions_windows.ps1 `
  -Source "<source>" -Command export -Cursor "<plugin-cursor>" -Json
```

If no matching cursor was returned, request a structured full export.

On macOS:

```zsh
/usr/bin/osascript -l JavaScript scripts/export_sessions_macos.js -- \
  --source "<source>" export --all --json
```

On Windows:

```powershell
powershell -NoProfile -File scripts/export_sessions_windows.ps1 `
  -Source "<source>" -Command export -All -Json
```

For either non-empty export, the structured result contains `session_count`,
`output`, and a new `next_cursor` equal to the greatest session start timestamp
in the exported batch. For an incremental export, require the new cursor to be
strictly greater than the plugin cursor. Use the new cursor in the final import
request:

```json
{"asset_type":6,"next_cursor":1789472460000}
```

When `session_count` is `0`, `output` is `null` and no package or import request
is created. An empty incremental export returns the previous cursor; an empty
full export returns `next_cursor: null`.

## Export

Use an output path explicitly supplied by the user. Otherwise use the selected
adapter's default `<source>-sessions.jsonl` path.

On macOS, export one session by stable session ID:

```zsh
/usr/bin/osascript -l JavaScript scripts/export_sessions_macos.js -- \
  --source "<source>" export \
  --session-id "<session-id>"
```

Repeat `--session-id` to export multiple selected sessions:

```zsh
/usr/bin/osascript -l JavaScript scripts/export_sessions_macos.js -- \
  --source "<source>" export \
  --session-id "<first-session-id>" \
  --session-id "<second-session-id>"
```

An exact title can be used when discovery proves it is unambiguous:

```zsh
/usr/bin/osascript -l JavaScript scripts/export_sessions_macos.js -- \
  --source "<source>" export \
  --title "<exact-title>"
```

Export every visible session only when the user explicitly requests all:

```zsh
/usr/bin/osascript -l JavaScript scripts/export_sessions_macos.js -- \
  --source "<source>" export --all
```

On Windows, use the equivalent PowerShell parameters:

```powershell
powershell -NoProfile -File scripts/export_sessions_windows.ps1 `
  -Source "<source>" -Command export -SessionId "<session-id>"
```

Set a custom destination with `--output "<path>"` on macOS or
`-Output "<path>"` on Windows.

When a selection contains project conversations, the exporter also updates
the source's `<source>-import.jsonl` in the session output directory. Override
that path with `--asset-output "<path>"` on macOS or `-AssetOutput "<path>"`
on Windows.
When no selected conversation belongs to a project, do not emit any project
record and do not create or update an asset package for the session export.

By default, the exporter creates an asset package containing only the project
records selected by this invocation. It must not carry memory, handbook, skill,
or MCP records forward from an earlier export. For a combined export in the
same operation, first write the other requested assets to a fresh staging
package, then pass `--merge-asset-output` on macOS or `-MergeAssetOutput` on
Windows so the session exporter retains those current-operation records.
Never use the merge option with a package completed by an earlier request.

An adapter must refuse to replace an existing destination. Use its explicit
overwrite option (`--overwrite` or `-Overwrite`) only after the user approves
replacing the session file, an existing standalone asset package, or an
existing `project` collection in merge mode.

## Standalone JSONL Format

Write one compact JSON object per exported conversation:

```json
{"conversation_id":"conv_001","project_id":"<project_id>","title":"<title>","messages":[{"message_id":"msg_001","conversation_id":"conv_001","message_type":"query","content":[{"content_id":"1","content_type":"text","text":{"text":"<text>"}},{"content_id":"2","content_type":"attachment","attachment":{"type":8,"identifier":"<source-message-uuid>","local_item":{"name":"<name>","abs_path":"<absolute-path>","file_type":1}}}]},{"message_id":"msg_002","conversation_id":"conv_001","message_type":"answer","reply_message_id":"msg_001","content":[{"content_id":"1","content_type":"text","text":{"text":"<text>"}}]}],"message_ids":["msg_001","msg_002"]}
```

Write one compact project object per exported project to the source's
extensible `<source>-import.jsonl` asset package, alongside records such as
`agents_md`:

```json
{"item_type":"project","project_id":"<project_id>","name":"<name>","description":"<description>","conversation_ids":["conv_001","conv_002"]}
```

Requirements:

- The filename follows `<source>-sessions.jsonl`.
- Set the outer `conversation_id` to the source session ID. Do not emit
  `format_version`, `session_id`, or `started_at`.
- For QwenWork and WorkBuddy project conversations, set each conversation's
  `project_id`. Write the corresponding project records to the source's
  `<source>-import.jsonl`, never to `<source>-sessions.jsonl`. Each project's
  `conversation_ids` contains only conversations present in the current export.
- Retain `title`.
- Number messages in source order from 1 using `msg_001`, `msg_002`, and so
  on. Set each message's `conversation_id` to the outer `conversation_id`.
- Map source role `user` to `message_type: "query"` and `assistant` to
  `message_type: "answer"`.
- Set each answer's `reply_message_id` to the nearest preceding query's
  `message_id`. Reject a session that contains an answer before any query.
- Number `content_id` sequentially from `"1"` within each message, resetting
  the sequence for the next message. When visible Markdown text remains, emit
  it first with `content_type: "text"` and its value in `text.text`.
- For each exported attachment, append a content item with
  `content_type: "attachment"`. Set `attachment.type` to `8`,
  `attachment.identifier` to the source message UUID, and
  `attachment.local_item` to the source name, absolute path, and
  `file_type: 1`.
- A QwenWork message whose visible text consists only of an attachment
  reference contains only the attachment item, with `content_id: "1"`.
- Set the outer `message_ids` array to every `message_id` in message order.
- Every physical line contains exactly one complete session object.
- Embedded line breaks are escaped inside JSON strings.
- Records are ordered by the source last-update timestamp, then source session
  ID; those sorting fields are not emitted.
- Messages retain source order.
- The file uses UTF-8 without a byte-order mark.
- Every record, including the final record, ends with LF (`\n`).
- Conversation records intentionally have no `item_type`.
- Never mix records from different sources in one session file.
- Visual widgets and charts are not part of the text session format and
  are intentionally omitted.

## Doubao Import

The `AI资产导入豆包` plugin accepts the standalone session JSONL format defined
above. Keep this package separate from the source's extensible asset package.

For an import, migration, or sync request:

1. Read `references/import-to-doubao.md` completely and complete its plugin
   and session cursor preflight before creating or replacing the session
   package.
2. Request a structured incremental export when
   `doubao_get_import_config` returns a matching cursor; otherwise request a
   structured full export.
3. If the incremental or full selection is empty, stop without modifying a
   package or invoking the plugin.
4. Require the export result's new `next_cursor` to equal the greatest exported
   session start timestamp. For an incremental export, also require it to be
   strictly greater than the retrieved cursor. Then complete the validation
   below.
5. Upload the validated `<source>-sessions.jsonl` file through the Doubao
   client cloud upload capability. When project conversations were exported,
   also validate and upload the updated `<source>-import.jsonl` asset package.
6. Put the exact session URL in `session_url_list`; when a project package was
   emitted, put its exact URL in `asset_url`. Include `5` in `asset_types` when
   that package contains project records, always include `6` for the sessions,
   set the mapped `source_product` and `pc_uuid`, and put the export result's
   new cursor in `next_asset_cursors`.
7. Invoke the plugin's import tool once for that source, combining
   `asset_url` and `session_url_list` when other asset types are also selected.
8. Treat the sessions as imported only when the plugin explicitly reports
   success.

Do not add session records to `workbuddy-import.jsonl` or
`qwenwork-import.jsonl`, and do not convert sessions into memories, handbooks,
prompts, or another asset type.

## Validation

An adapter must build the complete JSONL content without changing the
destination, validate every physical line, and write a sibling temporary file.
It must read that file back as strict UTF-8, compare every parsed record with
the in-memory sessions, and atomically replace the requested destination only
after validation succeeds.

After export, report the source, session JSONL path, optional WorkBuddy asset
package path, session count, and new cursor. Do not print message content
unless the user explicitly asks to see it.

## Safety

- Never modify or delete source session files.
- Never expose internal instructions, reasoning, or tool payloads. Export only
  the explicit WorkBuddy user attachments defined above.
- Never treat internal maintenance jobs as user sessions.
- Never export all sessions unless the user explicitly requests all or
  `doubao_get_import_config` returns no matching session cursor for an import.
- Never guess or locally derive an import cursor.
- Never send the session file path where the plugin requires an uploaded URL.
- Never submit the retrieved lower-bound cursor as the new cursor after a
  non-empty export.
- Never derive the new cursor from the current time or local file timestamps.
- Never overwrite an existing session file without explicit approval.
- Never combine sessions with another asset type or source.
- Never claim a source is supported without a defined and validated adapter.
- Never invoke the final importer before validating the complete session file.
