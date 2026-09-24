# Package Handbooks for Doubao

Use this workflow only when the user wants to import or export a WorkBuddy or
QwenWork (千问办公) handbook, custom prompt, or `AGENTS.md`.

Before executing this workflow, read `references/jsonl-package-format.md`
completely and follow its shared package, conflict, validation, and safe-write
rules.

Write the handbook as one compact JSON object on one physical JSONL line:

```json
{"item_type":"agents_md","agents_md_config":{"content":""}}
```

Set `agents_md_config.content` to the source handbook text. Always use a JSON
parser and serializer so quotes, backslashes, control characters, and embedded
line breaks are escaped correctly. Do not construct JSON with string
concatenation or shell interpolation.

## Sources

- WorkBuddy: `$HOME/.workbuddy/app/app-config.json`
  - Read the JSON field `personalization.customPrompt`.
  - Write to `workbuddy-import.jsonl`.
- QwenWork: `$HOME/.qwenworkcn/awareness/main/AGENTS.md`
  - Read the complete file as UTF-8 text.
  - Write to `qwenwork-import.jsonl`.

Recognize source requests such as `workbuddy`, `千问办公`, `qwenworkcn`,
`QwenWork`, or `both`. When the user does not specify a source, inspect which
source files exist and ask the user to choose. Do not silently combine sources
unless the user requests both.

If a selected source file is missing, report that path and continue with
another explicitly selected source when possible.

For WorkBuddy, stop that source's export when `app-config.json` is invalid
JSON, `personalization.customPrompt` is missing, or the field is not a string.
Do not infer the handbook from another field.

For QwenWork, stop that source's export when `AGENTS.md` is not valid UTF-8.
Do not normalize line endings, trim whitespace, or add a trailing newline to
the handbook content.

## Output

Use an output directory explicitly supplied by the user. Otherwise default to
the user's `Downloads` directory.

For each new export request, write through a fresh staging package as defined
by `references/jsonl-package-format.md`. The `output_path` variables below
refer to that staging package while a mixed export is in progress.

The current request's fresh staging package may already contain other selected
item types. Preserve those records. Never read unrelated records from a
completed package produced by an earlier request. Append the `agents_md` record
when it is absent. If one `agents_md` record already exists in the staging
package, skip it by default and replace only that record after explicit
overwrite approval. Stop if duplicate `agents_md` records exist.

For either source, this same staging package may contain
`item_type: "project"` records produced by the session exporter during the
same request. Preserve all of them byte-for-byte when adding or replacing the
`agents_md` record.

## Packaging Workflow

1. Determine the requested source: WorkBuddy, QwenWork, or both.
2. Verify the selected source files.
3. Resolve the output directory and source-specific JSONL package paths.
4. Parse and validate every existing JSONL record without printing content.
5. Check the existing package for `item_type: "agents_md"` conflicts.
6. Show a concise plan listing each source, package, and append, replace, or
   skip action.
7. Parse or read the source content without printing it.
8. Serialize the handbook record and build the candidate JSONL package.
9. Validate a sibling temporary file, then atomically replace the package.
10. Report each package path and action without exposing handbook content.

## Windows Packaging

Use PowerShell's JSON parser and serializer. Write UTF-8 without a byte-order
mark and use LF as the JSONL record delimiter:

```powershell
$outputDirectory = Join-Path $HOME 'Downloads'
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Update-JsonlItem {
    param(
        [Parameter(Mandatory)]
        [string] $OutputPath,

        [Parameter(Mandatory)]
        [hashtable] $Item,

        [switch] $OverwriteItem
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $matches = [System.Collections.Generic.List[int]]::new()

    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        $text = [System.IO.File]::ReadAllText($OutputPath, $utf8)
        if ($text.Length -gt 0) {
            if (-not $text.EndsWith("`n")) {
                throw "JSONL package must end with LF: $OutputPath"
            }
            $existingLines = $text.Substring(0, $text.Length - 1).Split("`n")
            for ($index = 0; $index -lt $existingLines.Count; $index++) {
                $line = $existingLines[$index]
                if ([string]::IsNullOrEmpty($line) -or $line.Contains("`r")) {
                    throw "Invalid physical line in JSONL package: $OutputPath"
                }
                $value = $line | ConvertFrom-Json
                if (
                    $null -eq $value -or
                    $value -is [array] -or
                    $value.item_type -isnot [string] -or
                    [string]::IsNullOrEmpty($value.item_type)
                ) {
                    throw "Invalid JSONL record in package: $OutputPath"
                }
                $lines.Add($line)
                if ($value.item_type -ceq $Item.item_type) {
                    $matches.Add($index)
                }
            }
        }
    }

    if ($matches.Count -gt 1) {
        throw "Duplicate item_type '$($Item.item_type)' in $OutputPath"
    }

    $itemJson = $Item | ConvertTo-Json -Depth 4 -Compress
    if ($matches.Count -eq 1) {
        if (-not $OverwriteItem) {
            throw "Item type '$($Item.item_type)' already exists"
        }
        $lines[$matches[0]] = $itemJson
    } else {
        $lines.Add($itemJson)
    }

    $candidate = [string]::Join("`n", $lines) + "`n"
    $temporaryPath = "$OutputPath.tmp.$PID"
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $candidate, $utf8)
        $validated = [System.IO.File]::ReadAllText($temporaryPath, $utf8)
        if ($validated -cne $candidate) {
            throw "JSONL package validation failed: $OutputPath"
        }
        foreach ($line in $validated.Substring(
            0,
            $validated.Length - 1
        ).Split("`n")) {
            $null = $line | ConvertFrom-Json
        }
        if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
            $backupPath =
                "$OutputPath.backup.$([Guid]::NewGuid().ToString('N'))"
            [System.IO.File]::Replace(
                $temporaryPath,
                $OutputPath,
                $backupPath
            )
            Remove-Item -LiteralPath $backupPath -Force
        } else {
            [System.IO.File]::Move($temporaryPath, $OutputPath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
```

For WorkBuddy:

```powershell
$source = Join-Path $HOME '.workbuddy\app\app-config.json'
$output = Join-Path $outputDirectory 'workbuddy-import.jsonl'
$config = [System.IO.File]::ReadAllText($source, $utf8) | ConvertFrom-Json
$content = $config.personalization.customPrompt

if ($content -isnot [string]) {
    throw 'personalization.customPrompt is missing or is not a string'
}
$item = [ordered]@{
    item_type = 'agents_md'
    agents_md_config = [ordered]@{ content = $content }
}
Update-JsonlItem -OutputPath $output -Item $item
```

For QwenWork:

```powershell
$source = Join-Path $HOME '.qwenworkcn\awareness\main\AGENTS.md'
$output = Join-Path $outputDirectory 'qwenwork-import.jsonl'
$content = [System.IO.File]::ReadAllText($source, $utf8)
$item = [ordered]@{
    item_type = 'agents_md'
    agents_md_config = [ordered]@{ content = $content }
}
Update-JsonlItem -OutputPath $output -Item $item
```

Pass `-OverwriteItem` only after explicit approval to replace an existing
`agents_md` record.

## macOS Packaging

Use the built-in JavaScript for Automation runtime through
`/usr/bin/osascript`. It provides structured JSON parsing and serialization
without requiring an additional runtime. Pass paths as arguments; never embed
handbook content in the command.

```zsh
output_directory="$HOME/Downloads"
source_type="workbuddy"
source_path="$HOME/.workbuddy/app/app-config.json"
output_path="$output_directory/workbuddy-import.jsonl"
overwrite_item="false"
temporary_path="$output_path.tmp.$$"

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

function parseJsonl(text, path) {
  if (text === "") {
    return [];
  }
  if (!text.endsWith("\n")) {
    throw new Error("JSONL package must end with LF: " + path);
  }

  const lines = text.slice(0, -1).split("\n");
  return lines.map(function (raw, index) {
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

function run(argv) {
  const sourceType = argv[0];
  const sourcePath = argv[1];
  const outputPath = argv[2];
  const temporaryPath = argv[3];
  const overwriteItem = argv[4] === "true";
  let content;

  if (sourceType === "workbuddy") {
    const config = JSON.parse(readUtf8(sourcePath));
    if (
      !config.personalization ||
      typeof config.personalization.customPrompt !== "string"
    ) {
      throw new Error(
        "personalization.customPrompt is missing or is not a string"
      );
    }
    content = config.personalization.customPrompt;
  } else if (sourceType === "qwenwork") {
    content = readUtf8(sourcePath);
  } else {
    throw new Error("Unsupported source type: " + sourceType);
  }

  const manager = $.NSFileManager.defaultManager;
  const existingText = manager.fileExistsAtPath(outputPath)
    ? readUtf8(outputPath)
    : "";
  const records = parseJsonl(existingText, outputPath);
  const matchingIndexes = [];

  records.forEach(function (record, index) {
    if (record.value.item_type === "agents_md") {
      matchingIndexes.push(index);
    }
  });

  if (matchingIndexes.length > 1) {
    throw new Error("Duplicate item_type agents_md in " + outputPath);
  }
  if (matchingIndexes.length === 1 && !overwriteItem) {
    throw new Error("Item type agents_md already exists in " + outputPath);
  }

  const item = {
    item_type: "agents_md",
    agents_md_config: {content: content}
  };
  const itemJson = JSON.stringify(item);
  const lines = records.map(function (record) {
    return record.raw;
  });

  if (matchingIndexes.length === 1) {
    lines[matchingIndexes[0]] = itemJson;
  } else {
    lines.push(itemJson);
  }

  const candidate = lines.join("\n") + "\n";
  parseJsonl(candidate, temporaryPath);
  writeUtf8(temporaryPath, candidate);

  const validated = readUtf8(temporaryPath);
  const validatedRecords = parseJsonl(validated, temporaryPath);
  const validatedItem = validatedRecords.filter(function (record) {
    return record.value.item_type === "agents_md";
  });
  if (
    validated !== candidate ||
    validatedItem.length !== 1 ||
    validatedItem[0].value.agents_md_config.content !== content
  ) {
    manager.removeItemAtPathError(temporaryPath, null);
    throw new Error("JSONL package validation failed: " + outputPath);
  }
}
' -- \
  "$source_type" \
  "$source_path" \
  "$output_path" \
  "$temporary_path" \
  "$overwrite_item"

result=$?
if [[ $result -eq 0 ]]; then
  /bin/mv -f "$temporary_path" "$output_path"
else
  /bin/rm -f "$temporary_path"
fi
exit $result
```

For QwenWork, set:

```zsh
source_type="qwenwork"
source_path="$HOME/.qwenworkcn/awareness/main/AGENTS.md"
output_path="$output_directory/qwenwork-import.jsonl"
```

Run the command once per selected source. Set `overwrite_item="true"` only
after explicit approval to replace an existing `agents_md` record.

## Safety

- Never print or summarize handbook content unless the user explicitly asks.
- Never modify or delete the source configuration or handbook files.
- Never locate, read, or modify a local Doubao profile.
- Never merge WorkBuddy and QwenWork records into the same package.
- Never substitute another WorkBuddy configuration field for
  `personalization.customPrompt`.
- Never trim, normalize, or otherwise rewrite source content.
- Never append to an invalid JSONL package.
- Never create output when source parsing or UTF-8 decoding fails.
- Never replace an existing `agents_md` item without explicit approval.
