# Package MCP Servers for Doubao

Use this workflow only when the user wants to import or export MCP server
configurations from WorkBuddy, QwenWork (千问办公), or both.

Before executing this workflow, read `references/jsonl-package-format.md`
completely and follow its shared package, conflict, validation, and safe-write
rules.

`mcp` is a collection item type. Write one compact JSON object per eligible
MCP server:

```json
{"item_type":"mcp","mcp_config":{"unique_id":"<name>","name":"<name>","transport_type":2,"streamable_http":{"url":"<url>"}}}
```

Set `mcp_config.unique_id` to exactly the same string as `mcp_config.name`.
Always use a JSON parser and serializer. Never construct records with string
concatenation or shell interpolation.

## Sources

- WorkBuddy connector skill entries:
  `$HOME/.workbuddy/connectors/skills/<skill-name>/SKILL.md`
- WorkBuddy user-specific MCP configurations:
  `$HOME/.workbuddy/connectors/<guid>/mcp.json`
- WorkBuddy default MCP configuration:
  `$HOME/.workbuddy/connectors/default/mcp.json`
- WorkBuddy output package: `workbuddy-import.jsonl`
- QwenWork MCP configuration: `$HOME/.qwenworkcn/mcp.json`
- QwenWork output package: `qwenwork-import.jsonl`

For QwenWork, parse the top-level `mcpServers` object. Each own property is
one MCP server. Set `mcp_config.name` to the property key exactly and set
`mcp_config.streamable_http.url` to that property's `url` string exactly.
Do not normalize either value or export other fields from the server object.

For WorkBuddy, an eligible connector skill is an immediate child directory of
`connectors/skills` that contains a top-level `SKILL.md` and whose directory
name starts with `connector-`.

Use the skill directory name, not the `name` field inside `SKILL.md`, to derive
the MCP server key:

```text
connector-westock-mcp -> connector:westock-mcp
```

The output `mcp_config.name` is the exact MCP server key with only the leading
`connector:` removed:

```text
connector:westock-mcp -> westock-mcp
```

Do not remove any other occurrence of `connector:` and do not otherwise
normalize the name.

## WorkBuddy Configuration Resolution

Treat an immediate child directory of `connectors` as a GUID directory only
when its name matches this UUID form case-insensitively:

```text
xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

For each selected connector skill:

1. Build the exact `mcpServers` key from the skill directory name.
2. Parse every existing GUID directory's `mcp.json`.
3. Find exact, case-sensitive occurrences of that key under `mcpServers`.
4. If exactly one GUID configuration contains the key, use that entry.
5. If multiple GUID configurations contain the key, stop and report the
   ambiguous key. Do not choose one.
6. If no GUID configuration contains the key, parse
   `connectors/default/mcp.json` and use the matching entry there.
7. If neither location contains the key, stop and report it.

If a required `mcp.json` is invalid JSON or its `mcpServers` value is not an
object, stop the WorkBuddy MCP export. When a matched entry exists but its
`url` is missing, not a string, or empty, stop instead of falling back.

## QwenWork Configuration Resolution

For QwenWork, stop that source when `mcp.json` is invalid JSON,
`mcpServers` is not an object, or any selected server is not an object with a
non-empty string `url`.

Set `mcp_config.streamable_http.url` to the matched `url` string exactly. Do
not normalize it, follow it, expose it in logs, or export other configuration
fields.

Resolve every selected server for a source before changing its output package.
Each source export is all-or-nothing; do not emit a partial MCP collection.

## Selection

For WorkBuddy, when the user names connector skills, match exact eligible
skill directory names and export only those entries.

For QwenWork, when the user names MCP servers, match exact `mcpServers` keys
and export only those entries. Report missing names without substituting
similar names.

When the user does not name entries, select every eligible entry from that
source. Sort WorkBuddy skills by directory name and QwenWork servers by key
for deterministic MCP record order.

Do not modify the package when no eligible MCP records remain.

## Collection Conflicts

Preserve all non-`mcp` records in the selected source's package byte-for-byte
and in their original order. Never put WorkBuddy and QwenWork MCP records in
the same package.

When no `mcp` records exist, append the complete resolved collection. When one
or more `mcp` records already exist, skip the complete collection by default.
Replace all existing `mcp` records only after explicit overwrite approval.

During replacement, insert the new collection at the position of the first
old `mcp` record and remove the remaining old `mcp` records. Never append new
MCP records to an existing collection.

## Packaging Workflow

1. Determine the requested source: WorkBuddy, QwenWork, or both.
2. Verify each selected source path and parse its `mcpServers` configurations.
3. Discover eligible WorkBuddy connector skills or QwenWork server keys.
4. Apply source-specific exact-name selection and deterministic sorting.
5. Resolve every selected entry and validate its URL before changing output.
6. Resolve each source-specific output package.
7. Parse and validate every existing JSONL record without printing content.
8. Determine whether to append, replace, or skip each `mcp` collection.
9. Show a concise plan with source, MCP names, package path, and action. Do
   not show URLs.
10. Serialize each source's MCP records and build its candidate package.
11. Validate a sibling temporary file, then atomically replace the package.
12. Report each package path, action, and MCP names without exposing URLs.

## macOS Packaging

Use the built-in JavaScript for Automation runtime through
`/usr/bin/osascript` for filesystem discovery, strict UTF-8 decoding, JSON
parsing, serialization, and validation:

```zsh
source="workbuddy"
source_path="$HOME/.workbuddy/connectors"
output_directory="$HOME/Downloads"
output_path="$output_directory/workbuddy-import.jsonl"
temporary_path="$output_path.tmp.$$"
overwrite_collection="false"
```

For QwenWork:

```zsh
source="qwenwork"
source_path="$HOME/.qwenworkcn/mcp.json"
output_directory="$HOME/Downloads"
output_path="$output_directory/qwenwork-import.jsonl"
temporary_path="$output_path.tmp.$$"
overwrite_collection="false"
```

After setting the source-specific variables, run:

```zsh
/bin/mkdir -p "$output_directory"
/usr/bin/osascript -l JavaScript -e '
ObjC.import("Foundation");

function readUtf8(path) {
  const data = $.NSData.dataWithContentsOfFile(path);
  if (!data) {
    throw new Error("Cannot read source: " + path);
  }
  const value = $.NSString.alloc.initWithDataEncoding(
    data,
    $.NSUTF8StringEncoding
  );
  if (!value) {
    throw new Error("Source is not valid UTF-8: " + path);
  }
  return ObjC.unwrap(value);
}

function writeUtf8(path, value) {
  const data = $(value).dataUsingEncoding($.NSUTF8StringEncoding);
  if (!data.writeToFileAtomically(path, true)) {
    throw new Error("Cannot write temporary package: " + path);
  }
}

function listDirectory(path) {
  const values =
    $.NSFileManager.defaultManager.contentsOfDirectoryAtPathError(path, null);
  if (!values) {
    throw new Error("Cannot list directory: " + path);
  }
  return ObjC.deepUnwrap(values);
}

function parseJsonFile(path) {
  const value = JSON.parse(readUtf8(path));
  if (
    value === null ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    value.mcpServers === null ||
    typeof value.mcpServers !== "object" ||
    Array.isArray(value.mcpServers)
  ) {
    throw new Error("Invalid mcpServers object: " + path);
  }
  return value;
}

function parseJsonl(text, path) {
  if (text === "") {
    return [];
  }
  if (!text.endsWith("\n")) {
    throw new Error("JSONL package must end with LF: " + path);
  }
  return text.slice(0, -1).split("\n").map(function (raw, index) {
    if (raw === "" || raw.includes("\r")) {
      throw new Error(
        "Invalid physical line " + (index + 1) + " in " + path
      );
    }
    const value = JSON.parse(raw);
    if (
      value === null ||
      Array.isArray(value) ||
      typeof value !== "object" ||
      typeof value.item_type !== "string" ||
      value.item_type === ""
    ) {
      throw new Error(
        "Invalid JSONL record " + (index + 1) + " in " + path
      );
    }
    return {raw: raw, value: value};
  });
}

function selectExactNames(availableNames, selectedNames, label) {
  if (selectedNames.length === 0) {
    return availableNames;
  }
  selectedNames.forEach(function (name) {
    if (!availableNames.includes(name)) {
      throw new Error(label + " not found: " + name);
    }
  });
  return selectedNames.filter(function (name, index, values) {
    return values.indexOf(name) === index;
  }).sort();
}

function makeMcpItem(name, server) {
  if (
    server === null ||
    typeof server !== "object" ||
    Array.isArray(server) ||
    typeof server.url !== "string" ||
    server.url === ""
  ) {
    throw new Error("MCP server URL is missing or invalid: " + name);
  }
  return {
    item_type: "mcp",
    mcp_config: {
      unique_id: name,
      name: name,
      transport_type: 2,
      streamable_http: {url: server.url}
    }
  };
}

function workbuddyItems(connectorsRoot, selectedNames) {
  const manager = $.NSFileManager.defaultManager;
  const skillsRoot = connectorsRoot + "/skills";
  const defaultConfigPath = connectorsRoot + "/default/mcp.json";
  const uuidPattern =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  let skillNames = listDirectory(skillsRoot).filter(function (name) {
    return (
      name.startsWith("connector-") &&
      manager.fileExistsAtPath(skillsRoot + "/" + name + "/SKILL.md")
    );
  }).sort();

  skillNames = selectExactNames(
    skillNames,
    selectedNames,
    "Connector skill"
  );
  if (skillNames.length === 0) {
    throw new Error("No eligible connector skills found");
  }

  const guidConfigs = listDirectory(connectorsRoot).filter(function (name) {
    return uuidPattern.test(name);
  }).sort().map(function (name) {
    const path = connectorsRoot + "/" + name + "/mcp.json";
    if (!manager.fileExistsAtPath(path)) {
      return null;
    }
    return {path: path, value: parseJsonFile(path)};
  }).filter(function (entry) {
    return entry !== null;
  });

  let defaultConfig = null;
  return skillNames.map(function (skillName) {
    const serverKey = "connector:" + skillName.slice("connector-".length);
    const matches = guidConfigs.filter(function (config) {
      return Object.prototype.hasOwnProperty.call(
        config.value.mcpServers,
        serverKey
      );
    });

    if (matches.length > 1) {
      throw new Error("Ambiguous MCP server key: " + serverKey);
    }

    let server;
    if (matches.length === 1) {
      server = matches[0].value.mcpServers[serverKey];
    } else {
      if (defaultConfig === null) {
        defaultConfig = parseJsonFile(defaultConfigPath);
      }
      if (!Object.prototype.hasOwnProperty.call(
        defaultConfig.mcpServers,
        serverKey
      )) {
        throw new Error("MCP server key not found: " + serverKey);
      }
      server = defaultConfig.mcpServers[serverKey];
    }

    return makeMcpItem(
      serverKey.slice("connector:".length),
      server
    );
  });
}

function qwenworkItems(configPath, selectedNames) {
  const config = parseJsonFile(configPath);
  let serverNames = Object.keys(config.mcpServers).sort();
  serverNames = selectExactNames(serverNames, selectedNames, "MCP server");
  if (serverNames.length === 0) {
    throw new Error("No QwenWork MCP servers found");
  }
  return serverNames.map(function (serverName) {
    return makeMcpItem(serverName, config.mcpServers[serverName]);
  });
}

function run(argv) {
  const source = argv[0];
  const sourcePath = argv[1];
  const outputPath = argv[2];
  const temporaryPath = argv[3];
  const overwriteCollection = argv[4] === "true";
  const selectedNames = argv.slice(5);
  const manager = $.NSFileManager.defaultManager;
  let items;
  if (source === "workbuddy") {
    items = workbuddyItems(sourcePath, selectedNames);
  } else if (source === "qwenwork") {
    items = qwenworkItems(sourcePath, selectedNames);
  } else {
    throw new Error("Unsupported MCP source: " + source);
  }

  const existingText = manager.fileExistsAtPath(outputPath)
    ? readUtf8(outputPath)
    : "";
  const records = parseJsonl(existingText, outputPath);
  const existingMcp = records.filter(function (record) {
    return record.value.item_type === "mcp";
  });
  if (existingMcp.length > 0 && !overwriteCollection) {
    throw new Error("MCP collection already exists in " + outputPath);
  }

  const previousOtherLines = records.filter(function (record) {
    return record.value.item_type !== "mcp";
  }).map(function (record) {
    return record.raw;
  });
  const itemLines = items.map(function (item) {
    return JSON.stringify(item);
  });
  const candidateLines = [];
  let inserted = false;

  records.forEach(function (record) {
    if (record.value.item_type === "mcp") {
      if (!inserted) {
        Array.prototype.push.apply(candidateLines, itemLines);
        inserted = true;
      }
    } else {
      candidateLines.push(record.raw);
    }
  });
  if (!inserted) {
    Array.prototype.push.apply(candidateLines, itemLines);
  }

  const candidate = candidateLines.join("\n") + "\n";
  parseJsonl(candidate, temporaryPath);
  writeUtf8(temporaryPath, candidate);

  const validated = readUtf8(temporaryPath);
  const validatedRecords = parseJsonl(validated, temporaryPath);
  const validatedMcp = validatedRecords.filter(function (record) {
    return record.value.item_type === "mcp";
  });
  const validatedOtherLines = validatedRecords.filter(function (record) {
    return record.value.item_type !== "mcp";
  }).map(function (record) {
    return record.raw;
  });

  if (
    validated !== candidate ||
    validatedMcp.length !== items.length ||
    JSON.stringify(validatedOtherLines) !==
      JSON.stringify(previousOtherLines)
  ) {
    manager.removeItemAtPathError(temporaryPath, null);
    throw new Error("JSONL MCP collection validation failed");
  }

  validatedMcp.forEach(function (record, index) {
    const expected = items[index].mcp_config;
    const actual = record.value.mcp_config;
    if (
      !actual ||
      typeof actual.unique_id !== "string" ||
      actual.unique_id !== expected.unique_id ||
      actual.unique_id !== actual.name ||
      actual.name !== expected.name ||
      actual.transport_type !== 2 ||
      !actual.streamable_http ||
      actual.streamable_http.url !== expected.streamable_http.url
    ) {
      manager.removeItemAtPathError(temporaryPath, null);
      throw new Error("JSONL MCP record validation failed");
    }
  });
}
' -- \
  "$source" \
  "$source_path" \
  "$output_path" \
  "$temporary_path" \
  "$overwrite_collection"

result=$?
if [[ $result -eq 0 ]]; then
  /bin/mv -f "$temporary_path" "$output_path"
else
  /bin/rm -f "$temporary_path"
fi
exit $result
```

To export specific entries, append exact WorkBuddy connector skill directory
names or exact QwenWork `mcpServers` keys after `"$overwrite_collection"` in
the `osascript` invocation.

Set `overwrite_collection="true"` only after explicit approval to replace all
existing `mcp` records.

## Windows Packaging

Resolve the skill directory and use `scripts/export_mcp_windows.ps1`. The
exporter implements the same discovery, exact selection, configuration
precedence, collection replacement, strict UTF-8 validation, and safe-write
rules as the macOS workflow.

Export all eligible WorkBuddy connector MCP servers:

```powershell
powershell -NoProfile -File scripts/export_mcp_windows.ps1 `
  -Source workbuddy
```

Export all QwenWork MCP servers:

```powershell
powershell -NoProfile -File scripts/export_mcp_windows.ps1 `
  -Source qwenwork
```

Repeat `-Name` for an exact selection:

```powershell
powershell -NoProfile -File scripts/export_mcp_windows.ps1 `
  -Source qwenwork `
  -Name "<first-server-name>","<second-server-name>"
```

Set a custom destination with `-Output "<path>"`. Pass
`-OverwriteCollection` only after explicit approval to replace all existing
`mcp` records. Add `-Json` for a structured result; it reports names and counts
but never URLs.

## Safety

- Never print, log, summarize, or probe MCP URLs.
- Never export fields outside the defined `mcp_config` schema. Export only the
  name-matching ID, derived name, fixed transport type, and exact URL.
- For WorkBuddy, never export a connector without a top-level `SKILL.md`.
- For WorkBuddy, never infer MCP entries that lack a connector skill entry.
- For WorkBuddy, never use `default/mcp.json` when a GUID configuration
  contains the key.
- For WorkBuddy, never choose between duplicate GUID matches.
- Never emit a partial MCP collection.
- Never append to an existing `mcp` collection.
- Never replace an existing `mcp` collection without explicit approval.
- Never modify records belonging to another `item_type`.
- Never combine WorkBuddy and QwenWork records in one package.
