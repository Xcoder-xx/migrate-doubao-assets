# Package Memory Data for Doubao

Use this workflow only when the user wants to import or export memory data
from WorkBuddy, QwenWork (千问办公), or both. Memory data contains two
partitions: experiences and user preferences.

Before executing this workflow, read `references/jsonl-package-format.md`
completely and follow its shared package, conflict, validation, and safe-write
rules.

`memory` is a partitioned collection item type. Use `memory_config.type` as
the partition discriminator.

Write one compact JSON object per source experience file:

```json
{"item_type":"memory","memory_config":{"unique_id":"<current-timestamp>","type":2,"experience":{"name":"workbuddy","description":"","content":""}}}
```

Set `memory_config.unique_id` to the current Unix timestamp in milliseconds,
serialized as a decimal string when the record is created. Set
`memory_config.experience.name` to `workbuddy` for WorkBuddy records and
`qwenwork` for QwenWork records. Set
`memory_config.experience.description` to an empty string.
Set `memory_config.experience.content` to the complete source file text.
Preserve the exact property names and casing shown above. Always use a JSON
serializer; do not construct records with string concatenation or shell
interpolation.

Write one compact JSON object per source preference file:

```json
{"item_type":"memory","memory_config":{"unique_id":"<current-timestamp>","type":1,"preference":{"content":""}}}
```

Set `memory_config.unique_id` to the current Unix timestamp in milliseconds,
serialized as a decimal string when the record is created. Set
`memory_config.preference.content` to the complete source file text.

## Sources

- WorkBuddy experiences: `$HOME/.workbuddy/memory`
  - Select immediate regular files whose extension is exactly lowercase `.md`.
  - Do not recurse into child directories.
  - Ignore backup and temporary files such as `*.md.bak`.
  - Sort selected files by filename for deterministic record order.
  - Write the collection to `workbuddy-import.jsonl`.
- WorkBuddy preference: `$HOME/.workbuddy/SOUL.md`
  - Read the complete file as one preference.
  - Write it to `workbuddy-import.jsonl`.
- QwenWork experience: `$HOME/.qwenworkcn/awareness/main/MEMORY.md`
  - Read the complete file as one experience.
  - Write the collection to `qwenwork-import.jsonl`.
- QwenWork preference: `$HOME/.qwenworkcn/awareness/main/USER.md`
  - Read the complete file as one preference.
  - Write it to `qwenwork-import.jsonl`.

Every selected source file with non-empty content produces exactly one record.
Decode every source as strict UTF-8, then ignore it only when the decoded
content is the empty string. Do not treat whitespace-only content as empty. Do
not trim content, normalize line endings, concatenate files, split one file
into multiple records, or include source filenames in the output record.

When a selected source path is missing, report it and continue with another
explicitly selected source when possible. Do not create or modify a package
for a source with no non-empty eligible experience or preference files.

For each new export request, write through a fresh staging package as defined
by `references/jsonl-package-format.md`. The `output` and `output_path`
variables below refer to that staging package while a mixed export is in
progress.

## Partition Conflicts

Treat memory records with `memory_config.type: 1` as the preference partition
and records with `memory_config.type: 2` as the experience partition. Preserve
all records from other asset types or memory partitions selected in the same
request byte-for-byte and in their original order. Never carry records forward
from a completed package produced by an earlier request.

When no records exist in the selected partition, append its complete source
collection. When one or more records already exist in that partition, skip the
complete partition by default. Replace all records in the selected partition
with its current complete source collection only after explicit overwrite
approval.

During replacement, insert the new collection at the position of the first
old record in the selected partition and remove the remaining old records in
that partition. Never append partial records to an existing partition.

## Packaging Workflow

1. Determine the requested source: WorkBuddy, QwenWork, or both.
2. Determine whether the request covers experiences, preferences, or both.
3. Discover and sort the selected source files.
4. Read every source file as strict UTF-8 without printing its content and
   exclude files whose decoded content is empty from the collection.
5. Stop that source and partition without modifying its package when no
   non-empty records remain.
6. Resolve the output directory and source-specific JSONL package paths.
7. Parse and validate every existing JSONL record without printing content.
8. Determine whether to append, replace, or skip each selected partition.
9. Show a concise plan with source, partition, non-empty record count, package
   path, and action.
10. Serialize one record per non-empty source file and build the candidate.
11. Validate a sibling temporary file, then atomically replace the package.
12. Report each package path, action, and record count without exposing
    content.

## Windows Packaging

Use PowerShell's UTF-8 decoder and JSON parser. Write UTF-8 without a
byte-order mark and use LF as the JSONL record delimiter:

```powershell
$outputDirectory = Join-Path $HOME 'Downloads'
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Update-MemoryPartition {
    param(
        [Parameter(Mandatory)]
        [string] $OutputPath,

        [Parameter(Mandatory)]
        [ValidateSet(1, 2)]
        [int] $MemoryType,

        [Parameter(Mandatory)]
        [object[]] $Items,

        [switch] $OverwriteCollection
    )

    if ($Items.Count -eq 0) {
        throw "Cannot write an empty memory partition"
    }

    $records = [System.Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        $text = [System.IO.File]::ReadAllText($OutputPath, $utf8)
        if ($text.Length -gt 0) {
            if (-not $text.EndsWith("`n")) {
                throw "JSONL package must end with LF: $OutputPath"
            }
            $existingLines = $text.Substring(0, $text.Length - 1).Split("`n")
            foreach ($line in $existingLines) {
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
                $records.Add([pscustomobject]@{
                    Raw = $line
                    Value = $value
                })
            }
        }
    }

    $existingItems = @(
        $records | Where-Object {
            $_.Value.item_type -ceq 'memory' -and
            $_.Value.memory_config.type -eq $MemoryType
        }
    )
    if ($existingItems.Count -gt 0 -and -not $OverwriteCollection) {
        throw "Memory partition '$MemoryType' already exists in $OutputPath"
    }
    $previousOtherLines = @(
        $records |
            Where-Object {
                -not (
                    $_.Value.item_type -ceq 'memory' -and
                    $_.Value.memory_config.type -eq $MemoryType
                )
            } |
            ForEach-Object { $_.Raw }
    )

    $itemLines = @(
        $Items | ForEach-Object {
            if (
                $_.item_type -cne 'memory' -or
                $_.memory_config.type -ne $MemoryType
            ) {
                throw "Collection item has the wrong memory partition"
            }
            $_ | ConvertTo-Json -Depth 5 -Compress
        }
    )

    $candidateLines = [System.Collections.Generic.List[string]]::new()
    $inserted = $false
    foreach ($record in $records) {
        if (
            $record.Value.item_type -ceq 'memory' -and
            $record.Value.memory_config.type -eq $MemoryType
        ) {
            if (-not $inserted) {
                foreach ($itemLine in $itemLines) {
                    $candidateLines.Add($itemLine)
                }
                $inserted = $true
            }
        } else {
            $candidateLines.Add($record.Raw)
        }
    }
    if (-not $inserted) {
        foreach ($itemLine in $itemLines) {
            $candidateLines.Add($itemLine)
        }
    }

    $candidate = [string]::Join("`n", $candidateLines) + "`n"
    $temporaryPath = "$OutputPath.tmp.$PID"
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $candidate, $utf8)
        $validated = [System.IO.File]::ReadAllText($temporaryPath, $utf8)
        if ($validated -cne $candidate) {
            throw "JSONL package validation failed: $OutputPath"
        }

        $validatedItems = @()
        $validatedOtherLines = @()
        foreach ($line in $validated.Substring(
            0,
            $validated.Length - 1
        ).Split("`n")) {
            $value = $line | ConvertFrom-Json
            if (
                $value.item_type -ceq 'memory' -and
                $value.memory_config.type -eq $MemoryType
            ) {
                $validatedItems += $value
            } else {
                $validatedOtherLines += $line
            }
        }
        if (
            $validatedItems.Count -ne $Items.Count -or
            [string]::Join("`n", $validatedOtherLines) -cne
                [string]::Join("`n", $previousOtherLines)
        ) {
            throw "JSONL collection validation failed: $OutputPath"
        }

        for ($index = 0; $index -lt $Items.Count; $index++) {
            $expected = $Items[$index].memory_config
            $actual = $validatedItems[$index].memory_config
            if (
                $actual.unique_id -isnot [string] -or
                $actual.unique_id -cne $expected.unique_id -or
                $actual.type -ne $MemoryType
            ) {
                throw "JSONL memory validation failed: $OutputPath"
            }
            if ($MemoryType -eq 1) {
                if (
                    $actual.preference.content -cne
                        $expected.preference.content
                ) {
                    throw "JSONL preference validation failed: $OutputPath"
                }
            } elseif (
                $actual.experience.name -cne $expected.experience.name -or
                $actual.experience.description -cne '' -or
                $actual.experience.content -cne $expected.experience.content
            ) {
                throw "JSONL experience validation failed: $OutputPath"
            }
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

For WorkBuddy experiences:

```powershell
$memoryRoot = Join-Path $HOME '.workbuddy\memory'
$output = Join-Path $outputDirectory 'workbuddy-import.jsonl'
$memoryFiles = @(
    Get-ChildItem -LiteralPath $memoryRoot -File |
        Where-Object { $_.Extension -ceq '.md' } |
        Sort-Object -Property Name
)
$items = @(
    $memoryFiles | ForEach-Object {
        $content = [System.IO.File]::ReadAllText($_.FullName, $utf8)
        if ($content.Length -gt 0) {
            $uniqueId =
                [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString(
                    [Globalization.CultureInfo]::InvariantCulture
                )
            [ordered]@{
                item_type = 'memory'
                memory_config = [ordered]@{
                    unique_id = $uniqueId
                    type = 2
                    experience = [ordered]@{
                        name = 'workbuddy'
                        description = ''
                        content = $content
                    }
                }
            }
        }
    }
)
if ($items.Count -gt 0) {
    Update-MemoryPartition `
        -OutputPath $output `
        -MemoryType 2 `
        -Items $items
} else {
    Write-Output 'No non-empty WorkBuddy experiences found'
}
```

For QwenWork experience:

```powershell
$memoryPath = Join-Path $HOME '.qwenworkcn\awareness\main\MEMORY.md'
$output = Join-Path $outputDirectory 'qwenwork-import.jsonl'
$content = [System.IO.File]::ReadAllText($memoryPath, $utf8)
$items = @()
if ($content.Length -gt 0) {
    $uniqueId = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
    $items = @(
        [ordered]@{
            item_type = 'memory'
            memory_config = [ordered]@{
                unique_id = $uniqueId
                type = 2
                experience = [ordered]@{
                    name = 'qwenwork'
                    description = ''
                    content = $content
                }
            }
        }
    )
}
if ($items.Count -gt 0) {
    Update-MemoryPartition `
        -OutputPath $output `
        -MemoryType 2 `
        -Items $items
} else {
    Write-Output 'QwenWork experience is empty; package was not modified'
}
```

For WorkBuddy preference:

```powershell
$preferencePath = Join-Path $HOME '.workbuddy\SOUL.md'
$output = Join-Path $outputDirectory 'workbuddy-import.jsonl'
$content = [System.IO.File]::ReadAllText($preferencePath, $utf8)
$items = @()
if ($content.Length -gt 0) {
    $uniqueId = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
    $items = @(
        [ordered]@{
            item_type = 'memory'
            memory_config = [ordered]@{
                unique_id = $uniqueId
                type = 1
                preference = [ordered]@{ content = $content }
            }
        }
    )
}
if ($items.Count -gt 0) {
    Update-MemoryPartition `
        -OutputPath $output `
        -MemoryType 1 `
        -Items $items
} else {
    Write-Output 'WorkBuddy preference is empty; package was not modified'
}
```

For QwenWork preference:

```powershell
$preferencePath = Join-Path $HOME '.qwenworkcn\awareness\main\USER.md'
$output = Join-Path $outputDirectory 'qwenwork-import.jsonl'
$content = [System.IO.File]::ReadAllText($preferencePath, $utf8)
$items = @()
if ($content.Length -gt 0) {
    $uniqueId = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
    $items = @(
        [ordered]@{
            item_type = 'memory'
            memory_config = [ordered]@{
                unique_id = $uniqueId
                type = 1
                preference = [ordered]@{ content = $content }
            }
        }
    )
}
if ($items.Count -gt 0) {
    Update-MemoryPartition `
        -OutputPath $output `
        -MemoryType 1 `
        -Items $items
} else {
    Write-Output 'QwenWork preference is empty; package was not modified'
}
```

Pass `-OverwriteCollection` only after explicit approval to replace an
existing selected memory partition.

## macOS Packaging

Use zsh only to discover source files and finalize the validated temporary
package. Use the built-in JavaScript for Automation runtime through
`/usr/bin/osascript` for strict UTF-8 decoding, JSON parsing, serialization,
and validation.

For WorkBuddy experiences:

```zsh
output_directory="$HOME/Downloads"
memory_root="$HOME/.workbuddy/memory"
output_path="$output_directory/workbuddy-import.jsonl"
overwrite_collection="false"
temporary_path="$output_path.tmp.$$"
memory_type="2"
experience_name="workbuddy"
memory_paths=("$memory_root"/*.md(N.))

(( ${#memory_paths[@]} > 0 )) || {
  print -u2 "No eligible WorkBuddy experience files found"
  exit 1
}
```

For QwenWork experience:

```zsh
output_directory="$HOME/Downloads"
output_path="$output_directory/qwenwork-import.jsonl"
overwrite_collection="false"
temporary_path="$output_path.tmp.$$"
memory_type="2"
experience_name="qwenwork"
memory_paths=("$HOME/.qwenworkcn/awareness/main/MEMORY.md")
```

For WorkBuddy preference:

```zsh
output_directory="$HOME/Downloads"
output_path="$output_directory/workbuddy-import.jsonl"
overwrite_collection="false"
temporary_path="$output_path.tmp.$$"
memory_type="1"
experience_name=""
memory_paths=("$HOME/.workbuddy/SOUL.md")
```

For QwenWork preference:

```zsh
output_directory="$HOME/Downloads"
output_path="$output_directory/qwenwork-import.jsonl"
overwrite_collection="false"
temporary_path="$output_path.tmp.$$"
memory_type="1"
experience_name=""
memory_paths=("$HOME/.qwenworkcn/awareness/main/USER.md")
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

function run(argv) {
  const outputPath = argv[0];
  const temporaryPath = argv[1];
  const overwriteCollection = argv[2] === "true";
  const memoryType = Number(argv[3]);
  const experienceName = argv[4];
  const sourcePaths = argv.slice(5);

  if (sourcePaths.length === 0) {
    throw new Error("Cannot write an empty memory partition");
  }
  if (memoryType !== 1 && memoryType !== 2) {
    throw new Error("Unsupported memory type: " + memoryType);
  }

  const sourceContents = sourcePaths.map(readUtf8).filter(function (content) {
    return content !== "";
  });
  if (sourceContents.length === 0) {
    throw new Error(
      "No non-empty memory records found; package was not modified"
    );
  }
  const items = sourceContents.map(function (content) {
    const config = {
      unique_id: Date.now().toString(),
      type: memoryType
    };
    if (memoryType === 1) {
      config.preference = {content: content};
    } else {
      config.experience = {
        name: experienceName,
        description: "",
        content: content
      };
    }
    return {
      item_type: "memory",
      memory_config: config
    };
  });
  const itemLines = items.map(function (item) {
    return JSON.stringify(item);
  });

  const manager = $.NSFileManager.defaultManager;
  const existingText = manager.fileExistsAtPath(outputPath)
    ? readUtf8(outputPath)
    : "";
  const records = parseJsonl(existingText, outputPath);
  function isTargetMemory(record) {
    return (
      record.value.item_type === "memory" &&
      record.value.memory_config &&
      record.value.memory_config.type === memoryType
    );
  }
  const existingPartition = records.filter(function (record) {
    return isTargetMemory(record);
  });

  if (existingPartition.length > 0 && !overwriteCollection) {
    throw new Error(
      "Memory partition " + memoryType + " already exists in " + outputPath
    );
  }

  const previousOtherLines = records.filter(function (record) {
    return !isTargetMemory(record);
  }).map(function (record) {
    return record.raw;
  });

  const candidateLines = [];
  let inserted = false;
  records.forEach(function (record) {
    if (isTargetMemory(record)) {
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
  const validatedPartition = validatedRecords.filter(function (record) {
    return isTargetMemory(record);
  });
  const validatedOtherLines = validatedRecords.filter(function (record) {
    return !isTargetMemory(record);
  }).map(function (record) {
    return record.raw;
  });

  if (
    validated !== candidate ||
    validatedPartition.length !== sourceContents.length ||
    JSON.stringify(validatedOtherLines) !==
      JSON.stringify(previousOtherLines)
  ) {
    manager.removeItemAtPathError(temporaryPath, null);
    throw new Error("JSONL memory collection validation failed");
  }

  validatedPartition.forEach(function (record, index) {
    const config = record.value.memory_config;
    if (
      !config ||
      typeof config.unique_id !== "string" ||
      config.unique_id !== items[index].memory_config.unique_id ||
      config.type !== memoryType
    ) {
      manager.removeItemAtPathError(temporaryPath, null);
      throw new Error("JSONL memory record validation failed");
    }
    if (
      memoryType === 1 &&
      (
        !config.preference ||
        config.preference.content !== sourceContents[index]
      )
    ) {
      manager.removeItemAtPathError(temporaryPath, null);
      throw new Error("JSONL preference record validation failed");
    }
    if (
      memoryType === 2 &&
      (
        !config.experience ||
        config.experience.name !== experienceName ||
        config.experience.description !== "" ||
        config.experience.content !== sourceContents[index]
      )
    ) {
      manager.removeItemAtPathError(temporaryPath, null);
      throw new Error("JSONL experience record validation failed");
    }
  });
}
' -- \
  "$output_path" \
  "$temporary_path" \
  "$overwrite_collection" \
  "$memory_type" \
  "$experience_name" \
  "${memory_paths[@]}"

result=$?
if [[ $result -eq 0 ]]; then
  /bin/mv -f "$temporary_path" "$output_path"
else
  /bin/rm -f "$temporary_path"
fi
exit $result
```

Set `overwrite_collection="true"` only after explicit approval to replace all
existing records in the selected memory partition for that source.

## Safety

- Never print or summarize memory content unless the user explicitly asks.
- Never modify or delete source experience or preference files.
- Never export an experience or preference whose decoded content is the empty
  string.
- Never import backup, temporary, nested, or non-Markdown WorkBuddy
  experience files.
- Never merge WorkBuddy and QwenWork records into the same package.
- Never trim, normalize, concatenate, split, or otherwise rewrite experiences
  or preferences.
- Never append to an existing memory partition.
- Never replace an existing memory partition without explicit approval.
- Never remove or rewrite records from another memory partition.
- Never modify records belonging to another `item_type`.
- Never leave a temporary or known-invalid package as an upload candidate.
