# Package and Upload Skills for Doubao

Use this workflow only when the user wants to import or export skills.

Before executing this workflow, read `references/jsonl-package-format.md`
completely and follow its shared package, conflict, validation, and safe-write
rules.

Package valid user-installed skills from WorkBuddy, QwenWork (千问办公), or
both as ZIP archives. For an import, migration, or sync to Doubao, upload each
archive with the Doubao client's cloud file upload capability and write the
returned URL to the source-specific JSONL package. The user may package all
eligible skills from a selected source or name specific skills.

When the user explicitly requests only a local export or ZIP package, stop
after local archive validation. Do not upload or create a `skill` JSONL record
unless the user also requests import, migration, sync, or cloud upload.

Create one archive per selected source:

- `workbuddy-skills.zip`
- `qwenwork-skills.zip`

For an import flow, create one JSONL record per selected source after upload:

```json
{"item_type":"skill","skill_config":{"unique_id":"<current-timestamp>","zip_url":""}}
```

Set `skill_config.unique_id` to the current Unix timestamp in milliseconds,
serialized as a decimal string when the record is created.
Set `skill_config.zip_url` to the exact non-empty URL returned by the cloud
upload operation.

Each archive must contain the selected skill directories directly at its root.
Do not add a source-name wrapper directory. Do not locate or modify a local
Doubao profile, and do not copy skills into a local Doubao directory.

Use operating-system-native commands: PowerShell and `tar.exe` on Windows, and
built-in macOS utilities such as `/bin/zsh`, `/usr/bin/zip`, and
`/usr/bin/unzip` on macOS. Do not require Nushell, Python, Node.js, package
managers, or any additional runtime. Do not create a migration script or an
intermediate staging directory on the user's computer.

## Sources

- WorkBuddy user skills on Windows: `$HOME\.workbuddy\skills`
- WorkBuddy user skills on macOS: `$HOME/.workbuddy/skills`
- WorkBuddy connector skills on Windows:
  `$HOME\.workbuddy\connectors\skills`
- WorkBuddy connector skills on macOS:
  `$HOME/.workbuddy/connectors/skills`
- QwenWork on Windows: `$HOME\.qwenworkcn\skills`
- QwenWork on macOS: `$HOME/.qwenworkcn/skills`
- QwenWork built-ins on Windows:
  `$env:LOCALAPPDATA\Programs\QwenWorkCN\<version>\resources\skills`
- QwenWork built-ins on macOS:
  `/Applications/QwenWorkCN.app/Contents/Resources/skills`

Recognize source requests such as `workbuddy`, `千问办公`, `qwenworkcn`,
`QwenWork`, or `both`. When the user does not specify a source, inspect which
source directories exist and ask the user to choose. Do not silently combine
sources unless the user requests both.

The two WorkBuddy roots form one logical source and one archive. Inspect both
roots whenever WorkBuddy is selected. If one root is missing, report it and
continue with the other. Stop the WorkBuddy portion only when neither root
exists.

If another selected source directory is missing, report that path and continue
with another explicitly selected source when possible.

## Eligibility Rules

A source child directory is a skill only when it contains a top-level
`SKILL.md`. Ignore standalone files and nested `SKILL.md` files.

For WorkBuddy, combine every immediate child directory from both WorkBuddy
roots that contains a top-level `SKILL.md`.

Compare WorkBuddy directory names case-insensitively across the two roots. If
both roots contain the same eligible name, do not package either copy until the
user chooses which root supplies that skill. Continue with other non-conflicting
skills when possible.

For QwenWork, include a skill directory only when all these conditions hold:

- It contains a top-level `SKILL.md`.
- Its directory name does not start with `dingtalk-` or `lark-`,
  case-insensitively.
- Its directory name does not match a built-in skill name,
  case-insensitively.

On Windows, determine built-in names from immediate child directories of every
existing
`$env:LOCALAPPDATA\Programs\QwenWorkCN\<version>\resources\skills` directory.
Combine names across all installed versions before filtering user skills.

On macOS, determine built-in names from immediate child directories of
`/Applications/QwenWorkCN.app/Contents/Resources/skills`.

Compare built-in names case-insensitively on both platforms. Do not use
`.skill-metadata.yaml` to identify built-in skills.

These QwenWork exclusions are mandatory even when the user explicitly names an
excluded skill. Report why a requested skill was excluded.

Use native PowerShell discovery on Windows:

```powershell
$workbuddyRoots = [ordered]@{
    user = Join-Path $HOME '.workbuddy\skills'
    connector = Join-Path $HOME '.workbuddy\connectors\skills'
}
$qwenSource = Join-Path $HOME '.qwenworkcn\skills'
$qwenInstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\QwenWorkCN'

$workbuddySkills = @()
foreach ($entry in $workbuddyRoots.GetEnumerator()) {
    if (Test-Path -LiteralPath $entry.Value -PathType Container) {
        $workbuddySkills += Get-ChildItem -LiteralPath $entry.Value -Directory |
            Where-Object {
                Test-Path -LiteralPath (
                    Join-Path $_.FullName 'SKILL.md'
                ) -PathType Leaf
            } |
            ForEach-Object {
                [pscustomobject]@{
                    SourceKind = $entry.Key
                    SourceRoot = $entry.Value
                    Name = $_.Name
                    FullName = $_.FullName
                }
            }
    }
}
$workbuddyDuplicates = @(
    $workbuddySkills |
        Group-Object { $_.Name.ToLowerInvariant() } |
        Where-Object { $_.Count -gt 1 }
)

$builtInNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

$builtInRoots = @()
if (Test-Path -LiteralPath $qwenInstallRoot -PathType Container) {
    Get-ChildItem -LiteralPath $qwenInstallRoot -Directory | ForEach-Object {
        $builtInRoot = Join-Path $_.FullName 'resources\skills'
        if (Test-Path -LiteralPath $builtInRoot -PathType Container) {
            $builtInRoots += $builtInRoot
            Get-ChildItem -LiteralPath $builtInRoot -Directory | ForEach-Object {
                [void]$builtInNames.Add($_.Name)
            }
        }
    }
}

$qwenSkills = @()
if (Test-Path -LiteralPath $qwenSource -PathType Container) {
    $qwenSkills = @(
        Get-ChildItem -LiteralPath $qwenSource -Directory |
            Where-Object {
                $_.Name -notlike 'dingtalk-*' -and
                $_.Name -notlike 'lark-*' -and
                (Test-Path -LiteralPath (
                    Join-Path $_.FullName 'SKILL.md'
                ) -PathType Leaf) -and
                -not $builtInNames.Contains($_.Name)
            }
    )
}
```

Use native zsh discovery on macOS:

```zsh
workbuddy_roots=(
  "$HOME/.workbuddy/skills"
  "$HOME/.workbuddy/connectors/skills"
)
qwen_source="$HOME/.qwenworkcn/skills"
qwen_builtin_root="/Applications/QwenWorkCN.app/Contents/Resources/skills"

typeset -A qwen_builtin_names
for skill in "$qwen_builtin_root"/*(N/); do
  name="${skill:t}"
  qwen_builtin_names[${name:l}]=1
done

typeset -A workbuddy_name_counts
workbuddy_skills=()
for root in "${workbuddy_roots[@]}"; do
  [[ -d "$root" ]] || continue
  for skill in "$root"/*(N/); do
    [[ -f "$skill/SKILL.md" ]] || continue
    workbuddy_skills+=("$skill")
    name="${skill:t}"
    (( workbuddy_name_counts[${name:l}]++ ))
  done
done

workbuddy_duplicate_names=()
for name count in "${(@kv)workbuddy_name_counts}"; do
  (( count > 1 )) && workbuddy_duplicate_names+=("$name")
done

qwen_skills=()
for skill in "$qwen_source"/*(N/); do
  [[ -f "$skill/SKILL.md" ]] || continue
  name="${skill:t}"
  [[ "${name:l}" == dingtalk-* ]] && continue
  [[ "${name:l}" == lark-* ]] && continue
  [[ -n "${qwen_builtin_names[${name:l}]-}" ]] && continue
  qwen_skills+=("$skill")
done
```

Check that a source exists before enumerating it. For QwenWork packaging, also
verify the platform-specific built-in skills directory. On Windows, at least
one versioned `resources\skills` directory must exist. On macOS, the app
bundle's `Contents/Resources/skills` directory must exist. If the applicable
built-in directory cannot be found, stop the QwenWork portion and report that
built-in skills cannot be identified safely. Do not fall back to metadata-file
detection.

## Skill Selection

When the user names one or more skills, match exact directory names within the
eligible skills from the selected source. Package only those matches. Report
requested names that are missing or excluded; do not substitute similarly
named skills.

When the user does not name skills, select every eligible skill from the chosen
source.

For WorkBuddy, apply selection to the combined eligible skills from both roots.
Resolve every cross-root duplicate name before packaging. A selected
WorkBuddy skill must retain its source-root identity through packaging; do not
reduce the selection to names alone.

When both sources are selected, apply selection independently to each source.
Same-named skills may be included because the sources are written to separate
archives.

Do not create an archive for a source when no skills remain after validation
and selection.

## Output

Use an output directory explicitly supplied by the user. Otherwise default to
the user's `Downloads` directory:

- Windows: `$HOME\Downloads`
- macOS: `$HOME/Downloads`

Create the output directory if it does not exist. Use the fixed archive names
`workbuddy-skills.zip` and `qwenwork-skills.zip`.

Use the source-specific JSONL package in the same output directory:

- WorkBuddy: `workbuddy-import.jsonl`
- QwenWork: `qwenwork-import.jsonl`

If an archive already exists, skip it and report the conflict by default.
Replace it only when the user explicitly requests overwrite or confirms
replacement. Delete only the conflicting archive immediately before creating
its replacement.

For an import flow, `skill` is a singleton item type. Inspect and validate the
source-specific JSONL package before creating or uploading a new archive. When
no `skill` record exists, append it after upload. When exactly one exists, skip
the source by default and replace only that record after explicit overwrite
approval. Multiple `skill` records make the package invalid for this workflow.

For an import flow, resolve both the archive conflict and the JSONL `skill`
conflict before packaging or uploading. The archive and JSONL overwrite
decisions are independent; do not infer approval for one from approval for the
other.

## Packaging Workflow

1. Determine whether the user requested local export only or an import,
   migration, sync, or cloud upload.
2. Determine the requested source: WorkBuddy, QwenWork, or both.
3. Determine whether the user requested all eligible skills or specific names.
4. Verify the selected source directories and discover eligible skills.
5. Apply source-specific exclusions and exact-name selection.
6. Resolve the output directory and archive conflicts. For an import flow,
   also resolve JSONL `skill` conflicts.
7. Show a concise plan listing each source, output archive, included skills,
   and excluded or missing skills. For an import flow, also list the JSONL
   package and append or replace action.
8. Create one ZIP archive for each non-empty selected source.
9. Validate each archive and confirm every selected skill has a top-level
   `<skill-name>/SKILL.md` entry.
10. For a local-only export, report the archive and stop.
11. For an import flow, upload each validated ZIP with the Doubao client cloud
    upload capability.
12. Validate the returned URL and create the `skill` JSONL record.
13. Write and validate the updated source-specific JSONL package atomically.
14. Report the local archive, JSONL package, and packaged skill names.

## Cloud Upload

Perform this step only inside a Doubao client context that provides a cloud
file upload capability. The operation is:

1. Pass the validated local ZIP path to the client-provided file upload
   capability.
2. Wait for the structured upload result.
3. Extract the returned file URL without modifying it.
4. Require the URL to be a non-empty string.
5. Build this object with a JSON serializer, setting `unique_id` to the current
   Unix timestamp in milliseconds as a decimal string:

   ```json
   {"item_type":"skill","skill_config":{"unique_id":"<current-timestamp>","zip_url":"<uploaded-url>"}}
   ```

6. Append or replace the singleton `skill` record in the source-specific JSONL
   package according to the previously resolved conflict action.
7. Read the updated JSONL package back and verify that
   `skill_config.unique_id` exactly matches the generated timestamp string and
   `skill_config.zip_url` exactly matches the returned URL.

Use only the upload capability exposed by the Doubao client context. Do not
guess an upload endpoint, use `curl`, send the archive through `WebFetch`, or
implement an uploader in shell code.

If the client context has no upload capability, stop after local ZIP validation
and report that cloud upload is unavailable. Do not create a `skill` record.

If upload fails, is cancelled, or returns no non-empty URL, preserve the
existing JSONL package unchanged and do not write an empty or placeholder
`zip_url`. If upload succeeds but the JSONL update fails, report the uploaded
archive as unrecorded and preserve the previous JSONL package.

Treat a returned upload URL as potentially sensitive. Do not print or summarize
it unless the user explicitly asks.

## JSONL Update

Preserve every non-`skill` record byte-for-byte and in its original order.
Serialize the `skill` record as one compact physical line, write UTF-8 without
a byte-order mark, and terminate it with LF.

Build the complete candidate JSONL package before changing the destination.
Write it to a sibling temporary file, parse every line, verify the exact
uploaded URL, and atomically replace the destination only after validation.

When both WorkBuddy and QwenWork are selected, upload and update each source
independently:

- `workbuddy-skills.zip` URL goes only to `workbuddy-import.jsonl`.
- `qwenwork-skills.zip` URL goes only to `qwenwork-import.jsonl`.

Never place both URLs in one record or write a source's URL into the other
source's JSONL package.

## Native Packaging

Run the archiver from each source root and pass only immediate child directory
names. This keeps relative skill-directory paths at the archive root and
prevents absolute source paths from entering the ZIP. When a logical source
uses multiple roots, add each root's selected names to the same temporary
archive, then validate it before moving it to the final path.

On Windows, use the built-in `tar.exe` with ZIP format inferred from the
temporary archive's `.zip` extension. For WorkBuddy:

```powershell
$outputDirectory = Join-Path $HOME 'Downloads'
$archive = Join-Path $outputDirectory 'workbuddy-skills.zip'
$temporaryArchive = Join-Path (
    $outputDirectory
) "workbuddy-skills.tmp.$PID.zip"

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$tarArguments = @('-a', '-c', '-f', $temporaryArchive)
$selectedWorkbuddySkills |
    Group-Object -Property SourceRoot |
    ForEach-Object {
        $tarArguments += @('-C', $_.Name)
        $tarArguments += @(
            $_.Group |
                Sort-Object -Property Name |
                ForEach-Object { $_.Name }
        )
    }

& tar.exe @tarArguments
if ($LASTEXITCODE -ne 0) {
    Remove-Item -LiteralPath $temporaryArchive -Force -ErrorAction SilentlyContinue
    throw "Failed to create archive: $archive"
}
& tar.exe -t -f $temporaryArchive | Out-Null
if ($LASTEXITCODE -ne 0) {
    Remove-Item -LiteralPath $temporaryArchive -Force
    throw "Archive validation failed: $archive"
}
Move-Item -LiteralPath $temporaryArchive -Destination $archive -Force
```

For QwenWork, use one `-C $qwenSource` group with the selected QwenWork
directory names and `qwenwork-skills.zip`.

On macOS, use the built-in `/usr/bin/zip` from each WorkBuddy root. Preserve
symbolic links and omit Finder metadata:

```zsh
output_directory="$HOME/Downloads"
archive="$output_directory/workbuddy-skills.zip"
temporary_archive="$output_directory/workbuddy-skills.tmp.$$.zip"

/bin/mkdir -p "$output_directory"
[[ ! -e "$temporary_archive" ]] || exit 1

for root in "${workbuddy_roots[@]}"; do
  skill_names=()
  for skill in "${selected_workbuddy_skills[@]}"; do
    [[ "${skill:h}" == "$root" ]] || continue
    skill_names+=("${skill:t}")
  done
  (( ${#skill_names[@]} > 0 )) || continue

  (
    cd "$root" || exit 1
    COPYFILE_DISABLE=1 /usr/bin/zip -r -y \
      "$temporary_archive" "${skill_names[@]}" \
      -x '*/.DS_Store' '__MACOSX/*'
  ) || {
    /bin/rm -f "$temporary_archive"
    exit 1
  }
done

/usr/bin/unzip -tq "$temporary_archive" || {
  /bin/rm -f "$temporary_archive"
  exit 1
}
/bin/mv -f "$temporary_archive" "$archive"
```

For QwenWork, use the same temporary-archive pattern with one
`$qwen_source` root, the selected QwenWork directory names, and
`qwenwork-skills.zip`.

After validation, inspect the archive listing and ensure every selected skill
has a top-level `<skill-name>/SKILL.md` entry. Report and remove an archive that
fails validation; never leave a known-invalid package as an upload candidate.
Only then continue to the cloud upload step.

## Safety

- Never modify or delete source skills.
- Never locate, read, or modify a local Doubao profile.
- Never copy skills into a local Doubao directory.
- Never treat a directory without a top-level `SKILL.md` as a skill.
- Never package a QwenWork `dingtalk-*` or `lark-*` skill.
- Never package a QwenWork skill whose name matches a built-in skill.
- Never infer QwenWork built-in status from `.skill-metadata.yaml`.
- Never combine different sources in one archive.
- Never create an empty archive.
- Never replace an existing archive without explicit approval.
- Never put absolute paths or a source-name wrapper directory in an archive.
- Never choose between same-named WorkBuddy skills from different roots
  without user direction.
- Never upload an archive before ZIP and skill-layout validation succeeds.
- Never upload through a guessed endpoint or a shell/network workaround.
- Never create a `skill` JSONL record before upload returns a non-empty URL.
- Never write an empty, placeholder, inferred, or stale `zip_url`.
- Never replace an existing `skill` record without explicit approval.
- Never expose a returned upload URL unless the user explicitly asks.
