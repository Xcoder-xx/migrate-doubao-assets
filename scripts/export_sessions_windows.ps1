[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("qwenwork", "workbuddy")]
    [string] $Source,

    [Parameter(Mandatory)]
    [ValidateSet("list", "export")]
    [string] $Command,

    [string] $SourceRoot,
    [string[]] $SessionId = @(),
    [string[]] $Title = @(),
    [switch] $All,
    [string] $Cursor,
    [string] $Output,
    [string] $AssetOutput,
    [switch] $MergeAssetOutput,
    [switch] $Overwrite,
    [switch] $Json
)

$ErrorActionPreference = "Stop"
$cursorSpecified = $PSBoundParameters.ContainsKey("Cursor")
$Utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$SystemReminderPattern =
    '(?s)^(?:\s*<system-reminder(?:\s[^>]*)?>.*?</system-reminder>\s*)+'
$ImageLocalPathPattern =
    '(?is)<image_local_path(?:\s[^>]*)?>(.*?)</image_local_path>'
$InlineImageReferencePrefixPattern = '@image#\d+:'
$InlineQuotedFileReferencePattern =
    '@(["''])((?:/|[A-Za-z]:[\\/])[^\r\n]*?)\1'
$InlineFileReferencePattern = '@((?:/|[A-Za-z]:[\\/])[^\s<]+)'
$QwenWorkStructuredReferencePattern =
    '@\[(?:mcp-server|image|file):[^\]]+\]\s*'
$QwenWorkDatabaseImagePattern = '@\[image:base64:([^\]]+)\]\s*'
$QwenWorkDatabaseFilePattern = '@\[file:external:([^\]]+)\]\s*'
$QwenWorkReflectionMarkers = @(
    "Target file this round:",
    "Full MEMORY.md entries (indexed):",
    "Full USER.md entries (indexed):",
    "Please reflect and reorganize the target file."
)

function Read-StrictUtf8 {
    param([Parameter(Mandatory)][string] $Path)
    return [System.IO.File]::ReadAllText($Path, $Utf8)
}

function Resolve-OutputPath {
    param([Parameter(Mandatory)][string] $Path)
    return [IO.Path]::GetFullPath($Path)
}

function Test-SameOutputPath {
    param(
        [Parameter(Mandatory)][string] $Left,
        [Parameter(Mandatory)][string] $Right
    )
    return [StringComparer]::OrdinalIgnoreCase.Equals(
        (Resolve-OutputPath -Path $Left),
        (Resolve-OutputPath -Path $Right)
    )
}

function Complete-AtomicWrite {
    param(
        [Parameter(Mandatory)][string] $TemporaryPath,
        [Parameter(Mandatory)][string] $DestinationPath
    )

    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) {
        [IO.File]::Move($TemporaryPath, $DestinationPath)
        return
    }

    $backupPath =
        "$DestinationPath.backup.$([Guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::Replace(
            $TemporaryPath,
            $DestinationPath,
            $backupPath
        )
        Remove-Item -LiteralPath $backupPath -Force
    } catch {
        if (
            -not (Test-Path -LiteralPath $DestinationPath -PathType Leaf) -and
            (Test-Path -LiteralPath $backupPath -PathType Leaf)
        ) {
            [IO.File]::Move($backupPath, $DestinationPath)
        }
        throw
    }
}

function Read-Jsonl {
    param([Parameter(Mandatory)][string] $Path)

    $text = Read-StrictUtf8 -Path $Path
    if ($text.Length -eq 0) {
        return @()
    }
    $lines = $text -split "`n"
    if ($text.EndsWith("`n")) {
        $lines = $lines[0..($lines.Count - 2)]
    }

    $records = @()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index].TrimEnd("`r")
        if ($line.Length -eq 0) {
            throw "Blank JSONL line at ${Path}:$($index + 1)"
        }
        $value = $line | ConvertFrom-Json
        if ($null -eq $value -or $value -is [array]) {
            throw "Non-object JSONL value at ${Path}:$($index + 1)"
        }
        $records += $value
    }
    return $records
}

function Get-SessionId {
    param(
        [Parameter(Mandatory)][object[]] $Records,
        [Parameter(Mandatory)][string] $Path
    )

    $ids = @(
        $Records |
            ForEach-Object { $_.sessionId } |
            Where-Object { $_ -is [string] -and $_.Length -gt 0 } |
            Sort-Object -Unique
    )
    if ($ids.Count -ne 1) {
        throw "Expected one session ID in $Path"
    }
    return $ids[0]
}

function Convert-Timestamp {
    param($Value)
    if ($Value -is [string]) {
        return $Value
    }
    if (
        $Value -is [byte] -or
        $Value -is [int16] -or
        $Value -is [int32] -or
        $Value -is [int64] -or
        $Value -is [decimal] -or
        $Value -is [double]
    ) {
        return [DateTimeOffset]::FromUnixTimeMilliseconds(
            [int64] $Value
        ).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    }
    return ""
}

function Convert-DatabaseTimestamp {
    param($Value)
    if (
        $Value -is [byte] -or
        $Value -is [int16] -or
        $Value -is [int32] -or
        $Value -is [int64] -or
        $Value -is [decimal] -or
        $Value -is [double]
    ) {
        $milliseconds = [int64] $Value
        if ([Math]::Abs($milliseconds) -lt 100000000000) {
            $milliseconds *= 1000
        }
        return [DateTimeOffset]::FromUnixTimeMilliseconds(
            $milliseconds
        ).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    }
    return Convert-Timestamp -Value $Value
}

function ConvertTo-TimestampMilliseconds {
    param(
        $Value,
        [Parameter(Mandatory)][string] $Label
    )

    if (
        $Value -is [byte] -or
        $Value -is [int16] -or
        $Value -is [int32] -or
        $Value -is [int64] -or
        $Value -is [decimal] -or
        $Value -is [double]
    ) {
        return [int64] $Value
    }
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "$Label is missing"
    }

    $milliseconds = [int64] 0
    if ([int64]::TryParse($Value, [ref] $milliseconds)) {
        return $milliseconds
    }

    $timestamp = [DateTimeOffset]::MinValue
    $styles = (
        [Globalization.DateTimeStyles]::AssumeUniversal -bor
        [Globalization.DateTimeStyles]::AdjustToUniversal
    )
    if (
        [DateTimeOffset]::TryParse(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture,
            $styles,
            [ref] $timestamp
        )
    ) {
        return $timestamp.ToUnixTimeMilliseconds()
    }
    throw "$Label is not a valid ISO 8601 or Unix millisecond timestamp: $Value"
}

function Sort-SessionsByUpdatedAt {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Sessions
    )
    return @($Sessions | Sort-Object -Property updatedAt, sessionId)
}

function Get-ContentTexts {
    param(
        [Parameter(Mandatory)] $Record,
        [Parameter(Mandatory)][string[]] $AcceptedTypes
    )

    $content = $Record.content
    if ($null -eq $content -and $null -ne $Record.message) {
        $content = $Record.message.content
    }
    if ($null -eq $content) {
        return @()
    }
    return @(
        $content |
            Where-Object {
                $_.type -cin $AcceptedTypes -and $_.text -is [string]
            } |
            ForEach-Object { $_.text }
    )
}

function Remove-SystemReminder {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )
    return ([regex]::Replace($Text, $SystemReminderPattern, "")).Trim()
}

function Test-WorkBuddyMetaMessage {
    param([Parameter(Mandatory)] $Record)
    return (
        $Record.role -ceq "user" -and
        $Record.providerData.isMeta -eq $true
    )
}

function Test-QwenWorkReflectionPrompt {
    param([Parameter(Mandatory)][string] $Text)
    foreach ($marker in $QwenWorkReflectionMarkers) {
        if (-not $Text.Contains($marker)) {
            return $false
        }
    }
    return $true
}

function Initialize-WindowsSqlite {
    if ("DoubaoAssetWindowsSqlite" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class DoubaoAssetWindowsSqlite
{
    private const int SQLITE_OK = 0;
    private const int SQLITE_ROW = 100;
    private const int SQLITE_DONE = 101;
    private const int SQLITE_INTEGER = 1;
    private const int SQLITE_FLOAT = 2;
    private const int SQLITE_TEXT = 3;
    private const int SQLITE_BLOB = 4;
    private const int SQLITE_OPEN_READONLY = 1;

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(
        byte[] filename,
        out IntPtr database,
        int flags,
        IntPtr vfs
    );

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close_v2(IntPtr database);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_errmsg(IntPtr database);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_prepare_v2(
        IntPtr database,
        byte[] sql,
        int byteCount,
        out IntPtr statement,
        IntPtr tail
    );

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr statement);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr statement);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_column_count(IntPtr statement);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_column_name(IntPtr statement, int index);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_column_type(IntPtr statement, int index);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern long sqlite3_column_int64(IntPtr statement, int index);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern double sqlite3_column_double(IntPtr statement, int index);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_column_text(IntPtr statement, int index);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_column_blob(IntPtr statement, int index);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_column_bytes(IntPtr statement, int index);

    private static byte[] Utf8Z(string value)
    {
        return Encoding.UTF8.GetBytes(value + "\0");
    }

    private static string Utf8String(IntPtr pointer, int byteCount)
    {
        if (pointer == IntPtr.Zero || byteCount == 0) {
            return "";
        }
        byte[] bytes = new byte[byteCount];
        Marshal.Copy(pointer, bytes, 0, byteCount);
        return new UTF8Encoding(false, true).GetString(bytes);
    }

    private static string ErrorMessage(IntPtr database)
    {
        IntPtr pointer = sqlite3_errmsg(database);
        if (pointer == IntPtr.Zero) {
            return "Unknown SQLite error";
        }
        int length = 0;
        while (Marshal.ReadByte(pointer, length) != 0) {
            length++;
        }
        return Utf8String(pointer, length);
    }

    public static object[] Query(string path, string sql)
    {
        IntPtr database = IntPtr.Zero;
        IntPtr statement = IntPtr.Zero;
        var rows = new List<object>();
        int result = sqlite3_open_v2(
            Utf8Z(path),
            out database,
            SQLITE_OPEN_READONLY,
            IntPtr.Zero
        );
        if (result != SQLITE_OK) {
            string message = database == IntPtr.Zero
                ? "Cannot open SQLite database"
                : ErrorMessage(database);
            if (database != IntPtr.Zero) {
                sqlite3_close_v2(database);
            }
            throw new InvalidOperationException(message);
        }

        try {
            result = sqlite3_prepare_v2(
                database,
                Utf8Z(sql),
                -1,
                out statement,
                IntPtr.Zero
            );
            if (result != SQLITE_OK) {
                throw new InvalidOperationException(ErrorMessage(database));
            }

            int columnCount = sqlite3_column_count(statement);
            while ((result = sqlite3_step(statement)) == SQLITE_ROW) {
                var row = new Dictionary<string, object>(
                    StringComparer.Ordinal
                );
                for (int index = 0; index < columnCount; index++) {
                    IntPtr namePointer = sqlite3_column_name(statement, index);
                    int nameLength = 0;
                    while (Marshal.ReadByte(namePointer, nameLength) != 0) {
                        nameLength++;
                    }
                    string name = Utf8String(namePointer, nameLength);
                    int type = sqlite3_column_type(statement, index);
                    object value;
                    switch (type) {
                        case SQLITE_INTEGER:
                            value = sqlite3_column_int64(statement, index);
                            break;
                        case SQLITE_FLOAT:
                            value = sqlite3_column_double(statement, index);
                            break;
                        case SQLITE_TEXT:
                            value = Utf8String(
                                sqlite3_column_text(statement, index),
                                sqlite3_column_bytes(statement, index)
                            );
                            break;
                        case SQLITE_BLOB:
                            int length = sqlite3_column_bytes(statement, index);
                            byte[] bytes = new byte[length];
                            if (length > 0) {
                                Marshal.Copy(
                                    sqlite3_column_blob(statement, index),
                                    bytes,
                                    0,
                                    length
                                );
                            }
                            value = bytes;
                            break;
                        default:
                            value = null;
                            break;
                    }
                    row.Add(name, value);
                }
                rows.Add(row);
            }
            if (result != SQLITE_DONE) {
                throw new InvalidOperationException(ErrorMessage(database));
            }
            return rows.ToArray();
        }
        finally {
            if (statement != IntPtr.Zero) {
                sqlite3_finalize(statement);
            }
            sqlite3_close_v2(database);
        }
    }
}
'@
}

function Invoke-SqliteJson {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Sql
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    Initialize-WindowsSqlite
    try {
        return @(
            [DoubaoAssetWindowsSqlite]::Query(
                [IO.Path]::GetFullPath($Path),
                $Sql
            ) |
                ForEach-Object { [pscustomobject] $_ }
        )
    } catch {
        $exception = $_.Exception
        while ($null -ne $exception.InnerException) {
            $exception = $exception.InnerException
        }
        if ($exception -is [DllNotFoundException]) {
            $sqlite = Get-Command "sqlite3" -CommandType Application `
                -ErrorAction SilentlyContinue
            if ($null -eq $sqlite) {
                throw (
                    "Windows SQLite API and sqlite3.exe are unavailable; " +
                    "cannot read session data: $Path"
                )
            }
        } elseif ($exception.Message -notlike "*disk I/O error*") {
            throw
        } else {
            $snapshotRoot = Join-Path (
                [IO.Path]::GetTempPath()
            ) "doubao-asset-sqlite-$PID-$([Guid]::NewGuid().ToString('N'))"
            $snapshotPath = Join-Path (
                $snapshotRoot
            ) ([IO.Path]::GetFileName($Path))
            try {
                New-Item -ItemType Directory -Path $snapshotRoot | Out-Null
                $walPath = "$Path-wal"
                $lastSnapshotError = $null
                for ($attempt = 1; $attempt -le 3; $attempt++) {
                    $databaseBefore = Get-Item -LiteralPath $Path
                    $walBefore = if (
                        Test-Path -LiteralPath $walPath -PathType Leaf
                    ) {
                        Get-Item -LiteralPath $walPath
                    } else {
                        $null
                    }
                    [IO.File]::Copy($Path, $snapshotPath, $true)
                    if ($null -ne $walBefore) {
                        [IO.File]::Copy(
                            $walPath,
                            "$snapshotPath-wal",
                            $true
                        )
                    } elseif (
                        Test-Path `
                            -LiteralPath "$snapshotPath-wal" `
                            -PathType Leaf
                    ) {
                        Remove-Item -LiteralPath "$snapshotPath-wal" -Force
                    }

                    $databaseAfter = Get-Item -LiteralPath $Path
                    $walAfter = if (
                        Test-Path -LiteralPath $walPath -PathType Leaf
                    ) {
                        Get-Item -LiteralPath $walPath
                    } else {
                        $null
                    }
                    $databaseStable =
                        $databaseBefore.Length -eq $databaseAfter.Length -and
                        $databaseBefore.LastWriteTimeUtc.Ticks -eq
                            $databaseAfter.LastWriteTimeUtc.Ticks
                    $walStable =
                        ($null -eq $walBefore -and $null -eq $walAfter) -or
                        (
                            $null -ne $walBefore -and
                            $null -ne $walAfter -and
                            $walBefore.Length -eq $walAfter.Length -and
                            $walBefore.LastWriteTimeUtc.Ticks -eq
                                $walAfter.LastWriteTimeUtc.Ticks
                        )
                    if (-not $databaseStable -or -not $walStable) {
                        continue
                    }

                    try {
                        return @(
                            [DoubaoAssetWindowsSqlite]::Query(
                                $snapshotPath,
                                $Sql
                            ) |
                                ForEach-Object { [pscustomobject] $_ }
                        )
                    } catch {
                        $lastSnapshotError = $_
                    }
                }
                if ($null -ne $lastSnapshotError) {
                    throw $lastSnapshotError
                }
                throw (
                    "Could not capture a stable SQLite snapshot after " +
                    "three attempts: $Path"
                )
            } finally {
                if (Test-Path -LiteralPath $snapshotRoot -PathType Container) {
                    Remove-Item -LiteralPath $snapshotRoot -Recurse -Force
                }
            }
        }
    }

    $previousEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = $Utf8
        $output = @(
            & $sqlite.Source "-readonly" "-json" $Path $Sql 2>&1
        )
        if ($LASTEXITCODE -ne 0) {
            throw (
                "Cannot read session metadata database ${Path}: " +
                ($output -join "`n")
            )
        }
    } finally {
        [Console]::OutputEncoding = $previousEncoding
    }
    $text = ($output -join "`n").Trim()
    if ($text.Length -eq 0) {
        return @()
    }
    $parsed = $text | ConvertFrom-Json
    return [object[]] $parsed
}

function Get-WorkBuddySessionMetadata {
    $databasePath = Join-Path $HOME ".workbuddy\workbuddy.db"
    if (-not (Test-Path -LiteralPath $databasePath -PathType Leaf)) {
        throw "WorkBuddy session database not found: $databasePath"
    }
    $sql = @"
SELECT id,
       COALESCE(NULLIF(custom_title, ''), NULLIF(title, '')) AS title,
       created_at,
       updated_at,
       cwd,
       is_playground
FROM sessions
WHERE deleted_at IS NULL
ORDER BY updated_at, id
"@
    $sessions = @{}
    foreach ($row in @(Invoke-SqliteJson -Path $databasePath -Sql $sql)) {
        if ($row.id -is [string] -and $row.id.Length -gt 0) {
            $sessions[$row.id] = [pscustomobject]@{
                title = if ($row.title -is [string]) {
                    $row.title.Trim()
                } else {
                    ""
                }
                startedAt = Convert-DatabaseTimestamp $row.created_at
                updatedAt = Convert-DatabaseTimestamp $row.updated_at
                cwd = if ($row.cwd -is [string]) {
                    $row.cwd.TrimEnd([char[]] "\/")
                } else {
                    ""
                }
                isWorkspace = $row.is_playground -eq 0
            }
        }
    }
    return $sessions
}

function Merge-Attachments {
    param(
        [object[]] $Left = @(),
        [object[]] $Right = @()
    )

    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    return @(
        @($Left) + @($Right) |
            Where-Object {
                $null -ne $_ -and
                $_.absPath -is [string] -and
                $seen.Add($_.absPath)
            }
    )
}

function Get-QwenWorkDatabaseAttachments {
    param(
        [Parameter(Mandatory)] $Row,
        [Parameter(Mandatory)][object[]] $Parts
    )

    $metadata = try {
        $Row.metadata | ConvertFrom-Json
    } catch {
        [pscustomobject]@{}
    }
    $identifier = if (
        $metadata.sdkMessageUuid -is [string] -and
        $metadata.sdkMessageUuid.Length -gt 0
    ) {
        $metadata.sdkMessageUuid
    } else {
        $Row.message_id
    }
    $attachments = [System.Collections.Generic.List[object]]::new()
    foreach ($part in $Parts) {
        if ($part.type -ceq "text" -and $part.text -is [string]) {
            foreach (
                $match in
                [regex]::Matches($part.text, $QwenWorkDatabaseImagePattern)
            ) {
                $path = try {
                    $encoded = $match.Groups[1].Value
                    $remainder = $encoded.Length % 4
                    if ($remainder -ne 0) {
                        $encoded += "=" * (4 - $remainder)
                    }
                    [Text.Encoding]::UTF8.GetString(
                        [Convert]::FromBase64String($encoded)
                    )
                } catch {
                    ""
                }
                if ($path.Length -gt 0 -and [IO.File]::Exists($path)) {
                    $attachments.Add([pscustomobject]@{
                        name = [IO.Path]::GetFileName($path)
                        absPath = $path
                        identifier = $identifier
                    })
                }
            }
            foreach (
                $match in
                [regex]::Matches($part.text, $QwenWorkDatabaseFilePattern)
            ) {
                $path = $match.Groups[1].Value
                if ([IO.File]::Exists($path)) {
                    $attachments.Add([pscustomobject]@{
                        name = [IO.Path]::GetFileName($path)
                        absPath = $path
                        identifier = $identifier
                    })
                }
            }
        }

        $partType = if ($part.type -is [string]) { $part.type } else { "" }
        $toolName = if ($part.toolName -is [string]) {
            $part.toolName
        } else {
            ""
        }
        if (
            (
                $partType -cne "tool_use" -and
                -not $partType.EndsWith(
                    "qwenwork_file_present_files",
                    [StringComparison]::Ordinal
                )
            ) -or
            (
                $toolName -cne "present_files" -and
                -not $toolName.EndsWith(
                    "qwenwork_file_present_files",
                    [StringComparison]::Ordinal
                )
            ) -or
            $null -eq $part.input -or
            $null -eq $part.input.files
        ) {
            continue
        }
        foreach ($file in @($part.input.files)) {
            $path = if ($file -is [string]) {
                $file
            } elseif ($file.file_path -is [string]) {
                $file.file_path
            } else {
                ""
            }
            if ($path.Length -gt 0 -and [IO.File]::Exists($path)) {
                $attachments.Add([pscustomobject]@{
                    name = [IO.Path]::GetFileName($path)
                    absPath = $path
                    identifier = $identifier
                })
            }
        }
    }
    return @(Merge-Attachments -Right $attachments.ToArray())
}

function Get-QwenWorkDatabaseSessions {
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        throw "APPDATA is required to locate the QwenWork database"
    }
    $databasePath = Join-Path $env:APPDATA "QwenWorkCN\data\agents.db"
    if (-not (Test-Path -LiteralPath $databasePath -PathType Leaf)) {
        throw "QwenWork session database not found: $databasePath"
    }
    $sql = @"
WITH task_runs AS (
    SELECT task_id,
           chat_id,
           sub_chat_id,
           run_at,
           ROW_NUMBER() OVER (
               PARTITION BY sub_chat_id
               ORDER BY run_at DESC, id DESC
           ) AS run_rank
    FROM task_run_logs
    WHERE sub_chat_id IS NOT NULL
)
SELECT sc.session_id AS id,
       COALESCE(NULLIF(sc.name, ''), NULLIF(c.name, '')) AS title,
       lp.id AS local_project_id,
       lp.name AS local_project_name,
       tr.task_id AS scheduled_task_id,
       tr.run_at AS scheduled_run_at,
       sc.created_at AS session_created_at,
       sc.updated_at AS session_updated_at,
       m.sequence,
       m.message_id,
       m.role,
       m.parts,
       m.metadata,
       m.created_at AS message_created_at
FROM sub_chats sc
JOIN chats c ON c.id = sc.chat_id
LEFT JOIN local_projects lp
       ON lp.id = c.local_project_id
      AND lp.deleted_at IS NULL
LEFT JOIN task_runs tr
       ON tr.sub_chat_id = sc.id
      AND tr.chat_id = c.id
      AND tr.run_rank = 1
LEFT JOIN messages m ON m.sub_chat_id = sc.id
WHERE sc.session_id IS NOT NULL
ORDER BY sc.updated_at, sc.session_id, m.sequence
"@
    $sessions = @{}
    foreach ($row in @(Invoke-SqliteJson -Path $databasePath -Sql $sql)) {
        if ($row.id -isnot [string] -or $row.id.Length -eq 0) {
            continue
        }
        if (-not $sessions.ContainsKey($row.id)) {
            $sessions[$row.id] = [pscustomobject]@{
                sessionId = $row.id
                sourcePath = $databasePath
                title = if ($row.title -is [string]) {
                    $row.title.Trim()
                } else {
                    ""
                }
                startedAt = Convert-DatabaseTimestamp $row.session_created_at
                updatedAt = Convert-DatabaseTimestamp $row.session_updated_at
                projectId = if ($row.local_project_id -is [string]) {
                    $row.local_project_id
                } else {
                    ""
                }
                projectName = if ($row.local_project_name -is [string]) {
                    $row.local_project_name.Trim()
                } else {
                    ""
                }
                projectDescription = ""
                scheduledTaskId = if ($row.scheduled_task_id -is [string]) {
                    $row.scheduled_task_id
                } else {
                    ""
                }
                scheduledRunAt = if ($null -ne $row.scheduled_run_at) {
                    [int64] $row.scheduled_run_at
                } else {
                    [int64] 0
                }
                messages = [System.Collections.Generic.List[object]]::new()
            }
        }
        if (
            $row.role -cnotin @("user", "assistant") -or
            $row.parts -isnot [string]
        ) {
            continue
        }
        try {
            [object[]] $parts = $row.parts | ConvertFrom-Json
        } catch {
            throw "Invalid QwenWork message parts for $($row.id)"
        }
        $attachments = @(
            Get-QwenWorkDatabaseAttachments -Row $row -Parts $parts
        )
        $metadata = try {
            $row.metadata | ConvertFrom-Json
        } catch {
            [pscustomobject]@{}
        }
        $finalTextId = if (
            $row.role -ceq "assistant" -and
            $metadata.finalTextId -is [string]
        ) {
            $metadata.finalTextId
        } else {
            $null
        }
        $texts = @(
            $parts |
                Where-Object {
                    $_.type -ceq "text" -and
                    $_.text -is [string] -and
                    (
                        $row.role -ceq "user" -or
                        $_.id -ceq $finalTextId
                    )
                } |
                ForEach-Object { $_.text }
        )
        $content = Remove-SystemReminder -Text ($texts -join "`n`n")
        $content = (
            [regex]::Replace(
                $content,
                $QwenWorkStructuredReferencePattern,
                ""
            )
        ).Trim()
        if (
            $row.role -ceq "user" -and
            $content.Length -gt 0 -and
            (Test-QwenWorkReflectionPrompt -Text $content)
        ) {
            continue
        }
        if ($content.Length -eq 0 -and $attachments.Count -eq 0) {
            continue
        }
        $sessions[$row.id].messages.Add([pscustomobject][ordered]@{
            role = $row.role
            timestamp = Convert-DatabaseTimestamp $row.message_created_at
            content = $content
            attachments = $attachments
        })
    }

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($session in $sessions.Values) {
        $userMessages = @(
            $session.messages | Where-Object { $_.role -ceq "user" }
        )
        if ($userMessages.Count -eq 0) {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($session.title)) {
            $session.title = $userMessages[0].content
            if ([string]::IsNullOrWhiteSpace($session.title)) {
                $session.title = @(
                    $userMessages[0].attachments |
                        ForEach-Object { $_.name }
                ) -join ", "
            }
        }
        $session.messages = $session.messages.ToArray()
        $result.Add($session)
    }
    $latestScheduledSessionByTask = @{}
    foreach ($session in $result) {
        if ([string]::IsNullOrEmpty($session.scheduledTaskId)) {
            continue
        }
        $latest = $latestScheduledSessionByTask[$session.scheduledTaskId]
        if (
            $null -eq $latest -or
            $session.scheduledRunAt -gt $latest.scheduledRunAt -or
            (
                $session.scheduledRunAt -eq $latest.scheduledRunAt -and
                $session.sessionId -cgt $latest.sessionId
            )
        ) {
            $latestScheduledSessionByTask[$session.scheduledTaskId] = $session
        }
    }
    $filtered = @(
        $result.ToArray() | Where-Object {
            [string]::IsNullOrEmpty($_.scheduledTaskId) -or
            $latestScheduledSessionByTask[$_.scheduledTaskId].sessionId `
                -ceq $_.sessionId
        }
    )
    return @(Sort-SessionsByUpdatedAt -Sessions $filtered)
}

function Get-WorkBuddyAttachments {
    param([Parameter(Mandatory)] $Record)

    $attachments = [System.Collections.Generic.List[object]]::new()
    $identifier = if ($Record.id -is [string]) {
        $Record.id
    } else {
        $null
    }
    $content = $Record.content
    if ($null -eq $content -and $null -ne $Record.message) {
        $content = $Record.message.content
    }
    if ($null -eq $content) {
        return @()
    }

    foreach ($item in @($content)) {
        if (
            $item.type -cnotin @("input_text", "output_text", "text") -or
            $item.text -isnot [string]
        ) {
            continue
        }
        $itemText = if (
            $Record.role -ceq "user" -and
            $item.providerData.content -is [string]
        ) {
            $item.providerData.content
        } else {
            $item.text
        }

        foreach (
            $fileMatch in
            [regex]::Matches(
                $itemText,
                $InlineQuotedFileReferencePattern
            )
        ) {
            $path = $fileMatch.Groups[2].Value
            $attachments.Add([pscustomobject]@{
                name = [IO.Path]::GetFileName($path)
                absPath = $path
                identifier = $identifier
            })
        }
        $textWithoutQuotedFiles = [regex]::Replace(
            $itemText,
            $InlineQuotedFileReferencePattern,
            ""
        )
        foreach (
            $fileMatch in
            [regex]::Matches(
                $textWithoutQuotedFiles,
                $InlineFileReferencePattern
            )
        ) {
            $path = $fileMatch.Groups[1].Value
            $attachments.Add([pscustomobject]@{
                name = [IO.Path]::GetFileName($path)
                absPath = $path
                identifier = $identifier
            })
        }

        foreach (
            $imageMatch in
            [regex]::Matches($itemText, $ImageLocalPathPattern)
        ) {
            $path = (
                [Net.WebUtility]::HtmlDecode(
                    $imageMatch.Groups[1].Value
                )
            ).Trim()
            if ($path.Length -eq 0) {
                continue
            }
            $name = [IO.Path]::GetFileName($path)
            $attachments.Add([pscustomobject]@{
                name = $name
                absPath = $path
                identifier = $identifier
            })
        }
    }

    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    return @(
        $attachments |
            Where-Object { $seen.Add($_.absPath) }
    )
}

function Convert-WorkBuddyShareHtmlLinks {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    $pattern =
        '@share-html(?:#([^:\s@]+))?:(https?://[^\s@\u3400-\u9fff\uf900-\ufaff]*\.html(?:[?#][^\s@\u3400-\u9fff\uf900-\ufaff]*)?)'
    return [regex]::Replace(
        $Text,
        $pattern,
        {
            param($Match)

            $url = $Match.Groups[2].Value
            $encodedName = $Match.Groups[1].Value
            if ($encodedName.Length -eq 0) {
                $encodedName = (
                    ($url -split '[?#]', 2)[0] -split '/'
                )[-1]
            }
            try {
                $name = [Uri]::UnescapeDataString($encodedName)
            } catch {
                $name = $encodedName
            }

            $label = $name.Replace('\', '\\').
                Replace('[', '\[').
                Replace(']', '\]')
            $destination = $url.Replace('\', '\\').
                Replace('(', '\(').
                Replace(')', '\)')
            return "[$label]($destination)"
        },
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
}

function Remove-WorkBuddyAttachmentMarkup {
    param(
        [Parameter(Mandatory)][string] $Text,
        [object[]] $Attachments = @()
    )

    $value = Convert-WorkBuddyShareHtmlLinks -Text $Text
    $value = [regex]::Replace($value, $ImageLocalPathPattern, "")
    $value = [regex]::Replace($value, $InlineImageReferencePrefixPattern, "")
    $value = [regex]::Replace(
        $value,
        $InlineQuotedFileReferencePattern,
        {
            param($Match)
            return [IO.Path]::GetFileName($Match.Groups[2].Value)
        }
    )
    foreach ($attachment in $Attachments) {
        $value = $value.Replace(
            "@" + $attachment.absPath,
            $attachment.name
        )
    }
    return ([regex]::Replace($value, "[ `t]+(?=`r?`n)", "")).Trim()
}

function Get-WorkBuddyPresentedArtifacts {
    param([Parameter(Mandatory)][string] $SessionId)

    $indexPath = Join-Path (
        Join-Path $HOME ".workbuddy\artifact-index"
    ) "$SessionId.json"
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        return @{}
    }
    $index = Read-StrictUtf8 -Path $indexPath | ConvertFrom-Json
    $byRequestId = @{}
    foreach ($artifact in @($index.artifacts)) {
        $metadata = $artifact._meta
        $sourceTool = if ($metadata.sourceTool -is [string]) {
            $metadata.sourceTool.ToLowerInvariant().Replace("_", "")
        } else {
            ""
        }
        if (
            $null -eq $metadata -or
            $metadata.ownerConversationId -cne $SessionId -or
            $sourceTool -cne "presentfiles" -or
            $metadata.requestId -isnot [string] -or
            $artifact.uri -isnot [string]
        ) {
            continue
        }
        $uri = [Uri] $artifact.uri
        if (-not $uri.IsFile -or -not [IO.File]::Exists($uri.LocalPath)) {
            continue
        }
        if (-not $byRequestId.ContainsKey($metadata.requestId)) {
            $byRequestId[$metadata.requestId] = @()
        }
        $name = if (
            $artifact.name -is [string] -and
            -not [string]::IsNullOrWhiteSpace($artifact.name)
        ) {
            $artifact.name
        } else {
            [IO.Path]::GetFileName($uri.LocalPath)
        }
        $byRequestId[$metadata.requestId] += [pscustomobject]@{
            name = $name
            absPath = $uri.LocalPath
            identifier = $null
        }
    }
    foreach ($requestId in @($byRequestId.Keys)) {
        $byRequestId[$requestId] = @(
            Merge-Attachments -Right $byRequestId[$requestId]
        )
    }
    return $byRequestId
}

function New-Session {
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Messages,
        [string] $ExplicitTitle
    )

    $userMessages = @($Messages | Where-Object { $_.role -ceq "user" })
    if ($userMessages.Count -eq 0) {
        return $null
    }
    $title = $ExplicitTitle
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = (
            $userMessages[0].content -split "\r?`n"
        ) -join " "
        $title = ([regex]::Replace($title, "\s+", " ")).Trim()
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = @(
                $userMessages[0].attachments |
                    ForEach-Object { $_.name }
            ) -join ", "
        }
    }
    return [pscustomobject]@{
        sessionId = $Id
        sourcePath = $Path
        title = $title
        startedAt = $Messages[0].timestamp
        updatedAt = $Messages[$Messages.Count - 1].timestamp
        messages = $Messages
    }
}

function Get-WorkBuddyVisibleUserQueries {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    $tagPattern =
        '(?is)<(?<closing>/)?(?<name>[a-z][\w:.-]*)(?:\s[^>]*?)?(?<selfClosing>/?)>'
    $stack = [System.Collections.Generic.List[object]]::new()
    $queries = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Text, $tagPattern)) {
        $name = $match.Groups["name"].Value.ToLowerInvariant()
        $isClosing = $match.Groups["closing"].Success
        if (-not $isClosing) {
            if ($match.Groups["selfClosing"].Value -cne "/") {
                $stack.Add([pscustomobject]@{
                    Name = $name
                    ContentStart = $match.Index + $match.Length
                    IsTopLevelQuery = (
                        $name -ceq "user_query" -and $stack.Count -eq 0
                    )
                })
            }
            continue
        }

        $openIndex = -1
        for ($index = $stack.Count - 1; $index -ge 0; $index--) {
            if ($stack[$index].Name -ceq $name) {
                $openIndex = $index
                break
            }
        }
        if ($openIndex -lt 0) {
            continue
        }
        $openingTag = $stack[$openIndex]
        if ($openingTag.IsTopLevelQuery) {
            $queries.Add($Text.Substring(
                $openingTag.ContentStart,
                $match.Index - $openingTag.ContentStart
            ))
        }
        $stack.RemoveRange($openIndex, $stack.Count - $openIndex)
    }
    if ($queries.Count -gt 0) {
        return $queries.ToArray()
    }
    return @(
        [regex]::Replace(
            $Text,
            '(?is)<system-reminder(?:\s[^>]*)?>.*?</system-reminder>\s*',
            ""
        ).Trim()
    )
}

function Get-WorkBuddyUserTexts {
    param(
        [Parameter(Mandatory)] $Record,
        [object[]] $Attachments = @()
    )

    $values = [System.Collections.Generic.List[string]]::new()
    $content = $Record.content
    if ($null -eq $content -and $null -ne $Record.message) {
        $content = $Record.message.content
    }
    foreach ($item in @($content)) {
        if (
            $item.type -cnotin @("input_text", "text") -or
            $item.text -isnot [string]
        ) {
            continue
        }
        $rawText = if ($item.providerData.content -is [string]) {
            $item.providerData.content
        } else {
            $item.text
        }
        foreach (
            $visibleText in @(
                Get-WorkBuddyVisibleUserQueries -Text $rawText
            )
        ) {
            $cleaned = Remove-WorkBuddyAttachmentMarkup `
                -Text $visibleText `
                -Attachments $Attachments
            if ($cleaned.Length -gt 0) {
                $values.Add($cleaned)
            }
        }
    }
    return $values.ToArray()
}

function Add-WorkBuddyMessage {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]] $Messages,
        [Parameter(Mandatory)][string] $Role,
        [Parameter(Mandatory)][string] $Timestamp,
        [Parameter(Mandatory)][string] $Content,
        [AllowEmptyCollection()]
        [object[]] $Attachments = @()
    )

    $normalizedAttachments = @(
        $Attachments | Where-Object { $null -ne $_ }
    )
    if (
        $Role -ceq "assistant" -and
        $Messages.Count -gt 0 -and
        $Messages[$Messages.Count - 1].role -ceq "assistant"
    ) {
        $previous = $Messages[$Messages.Count - 1]
        $previous.content =
            $previous.content.TrimEnd() + "`n`n" + $Content.TrimStart()
        foreach ($attachment in $normalizedAttachments) {
            $previous.attachments += $attachment
        }
        return
    }
    $Messages.Add([pscustomobject][ordered]@{
        role = $Role
        timestamp = $Timestamp
        content = $Content
        attachments = $normalizedAttachments
    })
}

function Read-WorkBuddySession {
    param([Parameter(Mandatory)][string] $Path)

    $records = @(Read-Jsonl -Path $Path)
    $id = Get-SessionId -Records $records -Path $Path
    $messages = [System.Collections.Generic.List[object]]::new()
    $explicitTitle = $null
    $presentedArtifacts = Get-WorkBuddyPresentedArtifacts -SessionId $id

    foreach ($record in $records) {
        if ($record.type -ceq "ai-title") {
            if (
                $record.aiTitle -is [string] -and
                -not [string]::IsNullOrWhiteSpace($record.aiTitle)
            ) {
                $explicitTitle = $record.aiTitle.Trim()
            }
            continue
        }
        if ($record.type -cne "message") {
            continue
        }
        if ($record.role -cnotin @("user", "assistant")) {
            continue
        }
        if (Test-WorkBuddyMetaMessage -Record $record) {
            continue
        }
        if (
            $record.role -ceq "assistant" -and
            $null -ne $record.status -and
            $record.status -cne "completed"
        ) {
            continue
        }
        if (
            $record.role -ceq "assistant" -and
            $null -eq $record.PSObject.Properties["message"]
        ) {
            continue
        }

        $timestamp = Convert-Timestamp -Value $record.timestamp
        $attachments = @(Get-WorkBuddyAttachments -Record $record)
        if (
            $record.role -ceq "assistant" -and
            $null -ne $record.providerData
        ) {
            $requestId = if (
                $record.providerData.conversationRequestId -is [string]
            ) {
                $record.providerData.conversationRequestId
            } else {
                $record.providerData.traceId
            }
            if (
                $requestId -is [string] -and
                $presentedArtifacts.ContainsKey($requestId)
            ) {
                $artifactAttachments = @(
                    $presentedArtifacts[$requestId] |
                        ForEach-Object {
                            [pscustomobject]@{
                                name = $_.name
                                absPath = $_.absPath
                                identifier = $record.id
                            }
                        }
                )
                $attachments = @(
                    Merge-Attachments `
                        -Left $attachments `
                        -Right $artifactAttachments
                )
            }
        }
        $texts = @(
            if ($record.role -ceq "user") {
                Get-WorkBuddyUserTexts `
                    -Record $record `
                    -Attachments $attachments
            } else {
                Get-ContentTexts $record @("output_text", "text") |
                    ForEach-Object {
                        Remove-WorkBuddyAttachmentMarkup `
                            -Text $_ `
                            -Attachments $attachments
                    }
            }
        )
        for ($textIndex = 0; $textIndex -lt $texts.Count; $textIndex++) {
            $rawText = $texts[$textIndex]
            $content = $rawText.Trim()
            if ($content.Length -eq 0) {
                continue
            }
            Add-WorkBuddyMessage `
                -Messages $messages `
                -Role $record.role `
                -Timestamp $timestamp `
                -Content $content `
                -Attachments $(if ($textIndex -eq 0) {
                    $attachments
                } else {
                    @()
                })
        }
    }
    return New-Session `
        -Id $id `
        -Path $Path `
        -Messages ($messages.ToArray()) `
        -ExplicitTitle $explicitTitle
}

function Get-SourceConfiguration {
    param([Parameter(Mandatory)][string] $Name)
    if ($Name -ceq "qwenwork") {
        return [pscustomobject]@{
            Root = Join-Path $HOME ".qwenworkcn\projects"
            Output = Join-Path $HOME "Downloads\qwenwork-sessions.jsonl"
            AssetOutput = Join-Path $HOME "Downloads\qwenwork-import.jsonl"
        }
    }
    return [pscustomobject]@{
        Root = Join-Path $HOME ".workbuddy\projects"
        Output = Join-Path $HOME "Downloads\workbuddy-sessions.jsonl"
        AssetOutput = Join-Path $HOME "Downloads\workbuddy-import.jsonl"
    }
}

function Get-WorkBuddyWorkspaceKey {
    param([Parameter(Mandatory)][string] $SessionPath)

    $key = Split-Path -Leaf (Split-Path -Parent $SessionPath)
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "Cannot determine WorkBuddy workspace key from: $SessionPath"
    }
    return $key
}

function Get-Sessions {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $SourceName
    )

    if ($SourceName -ceq "qwenwork") {
        return @(Get-QwenWorkDatabaseSessions)
    }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Session directory not found: $Root"
    }
    $storedSessions = Get-WorkBuddySessionMetadata
    $pathsById = @{}
    foreach (
        $file in @(
            Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "*.jsonl"
        )
    ) {
        $id = $file.BaseName
        if (-not $storedSessions.ContainsKey($id)) {
            continue
        }
        if ($pathsById.ContainsKey($id)) {
            throw (
                "Duplicate session ID ${id}: " +
                "$($pathsById[$id]), $($file.FullName)"
            )
        }
        $pathsById[$id] = $file.FullName
    }
    $sessions = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $storedSessions.Keys) {
        if (-not $pathsById.ContainsKey($id)) {
            throw "WorkBuddy session event stream not found: $id"
        }
        $session = Read-WorkBuddySession -Path $pathsById[$id]
        if ($null -ne $session) {
            $metadata = $storedSessions[$id]
            $session.startedAt = $metadata.startedAt
            $session.updatedAt = $metadata.updatedAt
            if ($metadata.isWorkspace) {
                $projectId = Get-WorkBuddyWorkspaceKey `
                    -SessionPath $pathsById[$id]
                $projectName = [IO.Path]::GetFileName($metadata.cwd)
                $session |
                    Add-Member -NotePropertyName projectId `
                        -NotePropertyValue $projectId
                $session |
                    Add-Member -NotePropertyName projectName `
                        -NotePropertyValue $projectName
                $session |
                    Add-Member -NotePropertyName projectDescription `
                        -NotePropertyValue ""
            }
            if (-not [string]::IsNullOrWhiteSpace($metadata.title)) {
                $session.title = $metadata.title
            }
            $sessions.Add($session)
        }
    }
    return @(
        Sort-SessionsByUpdatedAt -Sessions $sessions.ToArray()
    )
}

function Select-Sessions {
    param([Parameter(Mandatory)][object[]] $Sessions)
    if ($All) {
        return $Sessions
    }
    if ($cursorSpecified) {
        $cursorMilliseconds = ConvertTo-TimestampMilliseconds `
            -Value $Cursor `
            -Label "Cursor"
        return @(
            $Sessions |
                Where-Object {
                    (
                        ConvertTo-TimestampMilliseconds `
                            -Value $_.startedAt `
                            -Label "Session $($_.sessionId) start timestamp"
                    ) -gt $cursorMilliseconds
                }
        )
    }

    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $SessionId) {
        $matches = @($Sessions | Where-Object { $_.sessionId -ceq $id })
        if ($matches.Count -eq 0) {
            throw "Session ID not found: $id"
        }
        $selected.Add($matches[0])
    }
    foreach ($requestedTitle in $Title) {
        $matches = @(
            $Sessions | Where-Object { $_.title -ceq $requestedTitle }
        )
        if ($matches.Count -eq 0) {
            throw "Session title not found: $requestedTitle"
        }
        if ($matches.Count -gt 1) {
            $ids = ($matches.sessionId -join ", ")
            throw "Ambiguous session title '$requestedTitle'; use a session ID: $ids"
        }
        $selected.Add($matches[0])
    }
    return @(
        Sort-SessionsByUpdatedAt -Sessions @(
            $selected | Sort-Object -Property sessionId -Unique
        )
    )
}

function ConvertTo-SessionRecord {
    param([Parameter(Mandatory)] $Session)

    $messages = [System.Collections.Generic.List[object]]::new()
    $messageIds = [System.Collections.Generic.List[string]]::new()
    $lastQueryMessageId = $null
    for ($index = 0; $index -lt $Session.messages.Count; $index++) {
        $message = $Session.messages[$index]
        $messageId = "msg_{0:D3}" -f ($index + 1)
        if ($message.role -ceq "user") {
            $messageType = "query"
            $lastQueryMessageId = $messageId
        } elseif ($message.role -ceq "assistant") {
            $messageType = "answer"
            if ($null -eq $lastQueryMessageId) {
                throw (
                    "Assistant message has no preceding user message in " +
                    "session $($Session.sessionId)"
                )
            }
        } else {
            throw "Unsupported message role: $($message.role)"
        }

        $record = [ordered]@{
            message_id = $messageId
            conversation_id = $Session.sessionId
            message_type = $messageType
        }
        if ($messageType -ceq "answer") {
            $record.reply_message_id = $lastQueryMessageId
        }
        $content = [System.Collections.Generic.List[object]]::new()
        if ($message.content.Length -gt 0) {
            $content.Add([pscustomobject][ordered]@{
                content_id = [string] ($content.Count + 1)
                content_type = "text"
                text = [ordered]@{ text = $message.content }
            })
        }
        $attachments = @(
            $message.attachments | Where-Object { $null -ne $_ }
        )
        for (
            $attachmentIndex = 0
            $attachmentIndex -lt $attachments.Count
            $attachmentIndex++
        ) {
            $attachment = $attachments[$attachmentIndex]
            $content.Add([pscustomobject][ordered]@{
                content_id = [string] ($content.Count + 1)
                content_type = "attachment"
                attachment = [ordered]@{
                    type = 8
                    identifier = $attachment.identifier
                    local_item = [ordered]@{
                        name = $attachment.name
                        abs_path = $attachment.absPath
                        file_type = 1
                    }
                }
            })
        }
        $record.content = $content.ToArray()
        $messages.Add([pscustomobject] $record)
        $messageIds.Add($messageId)
    }

    $record = [ordered]@{
        conversation_id = $Session.sessionId
        title = $Session.title
        messages = $messages.ToArray()
        message_ids = $messageIds.ToArray()
    }
    if (
        $Session.projectId -is [string] -and
        $Session.projectId.Length -gt 0
    ) {
        $record.project_id = $Session.projectId
    }
    return $record
}

function ConvertTo-ProjectRecords {
    param([Parameter(Mandatory)][object[]] $Sessions)

    $projects = [ordered]@{}
    foreach ($session in $Sessions) {
        if (
            $session.projectId -isnot [string] -or
            $session.projectId.Length -eq 0
        ) {
            continue
        }
        if (-not $projects.Contains($session.projectId)) {
            $projects[$session.projectId] = [ordered]@{
                item_type = "project"
                project_id = $session.projectId
                name = if ($session.projectName -is [string]) {
                    $session.projectName
                } else {
                    ""
                }
                description = if ($session.projectDescription -is [string]) {
                    $session.projectDescription
                } else {
                    ""
                }
                conversation_ids = [System.Collections.Generic.List[string]]::new()
            }
        }
        $project = $projects[$session.projectId]
        if (
            $project.name -cne $session.projectName -or
            $project.description -cne $session.projectDescription
        ) {
            throw "Conflicting project metadata: $($session.projectId)"
        }
        $project.conversation_ids.Add($session.sessionId)
    }
    return @(
        $projects.Values | ForEach-Object {
            $_.conversation_ids = $_.conversation_ids.ToArray()
            [pscustomobject] $_
        }
    )
}

function Assert-ProjectRecord {
    param([Parameter(Mandatory)] $Record)

    $conversationIds = @($Record.conversation_ids)
    if (
        $Record.item_type -cne "project" -or
        $Record.project_id -isnot [string] -or
        [string]::IsNullOrEmpty($Record.project_id) -or
        $Record.name -isnot [string] -or
        $Record.description -isnot [string] -or
        $conversationIds.Count -lt 1 -or
        @(
            $conversationIds |
                Where-Object {
                    $_ -isnot [string] -or [string]::IsNullOrEmpty($_)
                }
        ).Count -gt 0
    ) {
        throw "Invalid project record"
    }
}

function Assert-SessionRecord {
    param([Parameter(Mandatory)] $Record)

    $messages = @($Record.messages)
    $messageIds = @($Record.message_ids)
    if (
        $Record.conversation_id -isnot [string] -or
        [string]::IsNullOrEmpty($Record.conversation_id) -or
        $Record.title -isnot [string] -or
        $messages.Count -ne $messageIds.Count -or
        (
            $null -ne $Record.PSObject.Properties["project_id"] -and
            (
                $Record.project_id -isnot [string] -or
                [string]::IsNullOrEmpty($Record.project_id)
            )
        )
    ) {
        throw "Invalid session record"
    }

    $lastQueryMessageId = $null
    for ($index = 0; $index -lt $messages.Count; $index++) {
        $message = $messages[$index]
        $expectedId = "msg_{0:D3}" -f ($index + 1)
        $content = @($message.content)
        if (
            $message.message_id -cne $expectedId -or
            $messageIds[$index] -cne $expectedId -or
            $message.conversation_id -cne $Record.conversation_id -or
            $content.Count -lt 1
        ) {
            throw "Invalid message record in $($Record.conversation_id)"
        }
        for (
            $contentIndex = 0
            $contentIndex -lt $content.Count
            $contentIndex++
        ) {
            $contentItem = $content[$contentIndex]
            if ($contentItem.content_id -cne [string] ($contentIndex + 1)) {
                throw "Invalid message content in $($Record.conversation_id)"
            }
            if ($contentItem.content_type -ceq "text") {
                if ($contentItem.text.text -isnot [string]) {
                    throw "Invalid text content in $($Record.conversation_id)"
                }
                continue
            }
            $attachment = $contentItem.attachment
            $localItem = $attachment.local_item
            if (
                $contentItem.content_type -cne "attachment" -or
                $null -eq $attachment -or
                $attachment.type -ne 8 -or
                $attachment.identifier -isnot [string] -or
                [string]::IsNullOrEmpty($attachment.identifier) -or
                $null -eq $localItem -or
                $localItem.name -isnot [string] -or
                [string]::IsNullOrEmpty($localItem.name) -or
                $localItem.abs_path -isnot [string] -or
                [string]::IsNullOrEmpty($localItem.abs_path) -or
                $localItem.file_type -ne 1
            ) {
                throw "Invalid attachment content in $($Record.conversation_id)"
            }
        }

        if ($message.message_type -ceq "query") {
            $lastQueryMessageId = $message.message_id
        } elseif (
            $message.message_type -cne "answer" -or
            $null -eq $lastQueryMessageId -or
            $message.reply_message_id -cne $lastQueryMessageId
        ) {
            throw "Invalid answer linkage in $($Record.conversation_id)"
        }
    }
}

function ConvertFrom-AssetJsonlText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory)][string] $Path
    )

    if ($Text.Length -eq 0) {
        return @()
    }
    if (-not $Text.EndsWith("`n")) {
        throw "JSONL package must end with LF: $Path"
    }
    $records = [System.Collections.Generic.List[object]]::new()
    $lines = $Text.Substring(0, $Text.Length - 1).Split("`n")
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line.Length -eq 0 -or $line.Contains("`r")) {
            throw "Invalid JSONL line at ${Path}:$($index + 1)"
        }
        $value = $line | ConvertFrom-Json
        if (
            $null -eq $value -or
            $value -is [array] -or
            $value.item_type -isnot [string] -or
            [string]::IsNullOrEmpty($value.item_type)
        ) {
            throw "Invalid asset record at ${Path}:$($index + 1)"
        }
        $records.Add([pscustomobject]@{ raw = $line; value = $value })
    }
    return $records.ToArray()
}

function Prepare-ProjectPackage {
    param(
        [Parameter(Mandatory)][object[]] $Projects,
        [Parameter(Mandatory)][string] $Path
    )

    foreach ($project in $Projects) {
        Assert-ProjectRecord -Record $project
    }
    $outputExists = Test-Path -LiteralPath $Path -PathType Leaf
    if ($outputExists -and -not $MergeAssetOutput -and -not $Overwrite) {
        throw (
            "Asset destination already exists; pass -Overwrite to replace " +
            "it: $Path"
        )
    }
    $existingText = if ($outputExists -and $MergeAssetOutput) {
        Read-StrictUtf8 -Path $Path
    } else {
        ""
    }
    $existing = @(ConvertFrom-AssetJsonlText -Text $existingText -Path $Path)
    $existingProjects = @(
        $existing | Where-Object { $_.value.item_type -ceq "project" }
    )
    if ($existingProjects.Count -gt 0 -and -not $Overwrite) {
        throw (
            "Project collection already exists; pass -Overwrite to replace " +
            "it: $Path"
        )
    }

    $projectLines = @($Projects | ForEach-Object {
        $_ | ConvertTo-Json -Depth 10 -Compress
    })
    $lines = [System.Collections.Generic.List[string]]::new()
    $inserted = $false
    foreach ($record in $existing) {
        if ($record.value.item_type -ceq "project") {
            if (-not $inserted) {
                foreach ($line in $projectLines) {
                    $lines.Add($line)
                }
                $inserted = $true
            }
            continue
        }
        $lines.Add($record.raw)
    }
    if (-not $inserted) {
        foreach ($line in $projectLines) {
            $lines.Add($line)
        }
    }

    $candidate = [string]::Join("`n", $lines) + "`n"
    $parsed = @(
        ConvertFrom-AssetJsonlText -Text $candidate -Path $Path
    )
    $parsedProjectLines = @(
        $parsed |
            Where-Object { $_.value.item_type -ceq "project" } |
            ForEach-Object {
                Assert-ProjectRecord -Record $_.value
                $_.value | ConvertTo-Json -Depth 10 -Compress
            }
    )
    $existingOtherLines = @(
        $existing |
            Where-Object { $_.value.item_type -cne "project" } |
            ForEach-Object { $_.raw }
    )
    $parsedOtherLines = @(
        $parsed |
            Where-Object { $_.value.item_type -cne "project" } |
            ForEach-Object { $_.raw }
    )
    if (
        [string]::Join("`n", $parsedProjectLines) -cne
            [string]::Join("`n", $projectLines) -or
        [string]::Join("`n", $parsedOtherLines) -cne
            [string]::Join("`n", $existingOtherLines)
    ) {
        throw "In-memory project package validation failed"
    }
    return [pscustomobject]@{ Path = $Path; Candidate = $candidate }
}

function Write-ProjectPackage {
    param([Parameter(Mandatory)] $Prepared)

    $destinationPath = Resolve-OutputPath -Path $Prepared.Path
    $directory = [IO.Path]::GetDirectoryName($destinationPath)
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporaryPath = "$destinationPath.tmp.$PID"
    try {
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            $Prepared.Candidate,
            $Utf8
        )
        $validated = Read-StrictUtf8 -Path $temporaryPath
        if ($validated -cne $Prepared.Candidate) {
            throw "Project package byte validation failed"
        }
        $validatedRecords = @(
            ConvertFrom-AssetJsonlText `
                -Text $validated `
                -Path $temporaryPath
        )
        if ($validatedRecords.Count -eq 0) {
            throw "Project package validation failed"
        }
        Complete-AtomicWrite `
            -TemporaryPath $temporaryPath `
            -DestinationPath $destinationPath
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Write-Sessions {
    param(
        [Parameter(Mandatory)][object[]] $Sessions,
        [Parameter(Mandatory)][string] $Path
    )

    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not $Overwrite) {
        throw "Destination already exists; pass -Overwrite to replace it: $Path"
    }
    $records = @(
        $Sessions | ForEach-Object { ConvertTo-SessionRecord $_ }
    )
    foreach ($record in $records) {
        Assert-SessionRecord -Record $record
    }
    $lines = @($records | ForEach-Object {
        $_ | ConvertTo-Json -Depth 10 -Compress
    })
    $candidate = ($lines -join "`n") + "`n"

    foreach ($line in $lines) {
        $value = $line | ConvertFrom-Json
        if ($null -eq $value -or $value -is [array]) {
            throw "Invalid in-memory session JSONL record"
        }
    }

    $destinationPath = Resolve-OutputPath -Path $Path
    $directory = [IO.Path]::GetDirectoryName($destinationPath)
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporaryPath = "$destinationPath.tmp.$PID"
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $candidate, $Utf8)
        $validated = Read-StrictUtf8 -Path $temporaryPath
        if ($validated -cne $candidate) {
            throw "Session JSONL byte validation failed"
        }
        $validatedLines = $validated.Substring(
            0,
            $validated.Length - 1
        ).Split("`n")
        if ($validatedLines.Count -ne $records.Count) {
            throw "Session JSONL record validation failed"
        }
        for ($index = 0; $index -lt $records.Count; $index++) {
            $actual = $validatedLines[$index] | ConvertFrom-Json
            Assert-SessionRecord -Record $actual
            $actualJson = $actual | ConvertTo-Json -Depth 10 -Compress
            if ($actualJson -cne $lines[$index]) {
                throw "Session JSONL content validation failed"
            }
        }
        Complete-AtomicWrite `
            -TemporaryPath $temporaryPath `
            -DestinationPath $destinationPath
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

$configuration = Get-SourceConfiguration -Name $Source
$resolvedRoot = if ($SourceRoot) { $SourceRoot } else { $configuration.Root }
$sessions = @(Get-Sessions -Root $resolvedRoot -SourceName $Source)

if ($Command -ceq "list") {
    $summaries = @(
        $sessions | ForEach-Object {
            [ordered]@{
                session_id = $_.sessionId
                title = $_.title
                started_at = $_.startedAt
                message_count = $_.messages.Count
            }
        }
    )
    if ($Json) {
        ConvertTo-Json -InputObject $summaries -Depth 5
    } else {
        $summaries | ForEach-Object {
            "$($_.session_id)`t$($_.started_at)`t$($_.title)"
        }
    }
    exit 0
}

$selectorCount =
    [int] $All.IsPresent +
    [int] ($SessionId.Count -gt 0) +
    [int] ($Title.Count -gt 0) +
    [int] $cursorSpecified
if ($selectorCount -ne 1) {
    throw (
        "Export requires exactly one selector: " +
        "-All, -SessionId, -Title, or -Cursor"
    )
}

$selected = @(Select-Sessions -Sessions $sessions)
if ($selected.Count -eq 0) {
    if ($cursorSpecified) {
        if ($Json) {
            [ordered]@{
                source = $Source
                output = $null
                asset_output = $null
                session_count = 0
                next_cursor = (
                    ConvertTo-TimestampMilliseconds `
                        -Value $Cursor `
                        -Label "Cursor"
                )
            } | ConvertTo-Json -Compress
            exit 0
        }
        Write-Output "No sessions found after cursor $Cursor"
        exit 0
    }
    if ($All -and $Json) {
        [ordered]@{
            source = $Source
            output = $null
            asset_output = $null
            session_count = 0
            next_cursor = $null
        } | ConvertTo-Json -Compress
        exit 0
    }
    throw "No sessions selected"
}
$outputPath = if ($Output) { $Output } else { $configuration.Output }
$resolvedOutput = Resolve-OutputPath -Path $outputPath
$projectRecords = @(ConvertTo-ProjectRecords -Sessions $selected)
$resolvedAssetOutput = $null
$preparedProjectPackage = $null
if ($projectRecords.Count -gt 0) {
    $assetOutputPath = if ($AssetOutput) {
        $AssetOutput
    } elseif ($Output) {
        Join-Path `
            ([IO.Path]::GetDirectoryName($resolvedOutput)) `
            "$Source-import.jsonl"
    } else {
        $configuration.AssetOutput
    }
    $resolvedAssetOutput = Resolve-OutputPath -Path $assetOutputPath
    if (Test-SameOutputPath $resolvedAssetOutput $resolvedOutput) {
        throw "Session output and asset output must be different files"
    }
    $preparedProjectPackage = Prepare-ProjectPackage `
        -Projects $projectRecords `
        -Path $resolvedAssetOutput
}
Write-Sessions -Sessions $selected -Path $resolvedOutput
if ($null -ne $preparedProjectPackage) {
    Write-ProjectPackage -Prepared $preparedProjectPackage
}
$nextCursor = [int64]::MinValue
foreach ($session in $selected) {
    $sessionCursor = ConvertTo-TimestampMilliseconds `
        -Value $session.startedAt `
        -Label "Session $($session.sessionId) start timestamp"
    if ($sessionCursor -gt $nextCursor) {
        $nextCursor = $sessionCursor
    }
}
if ($Json) {
    [ordered]@{
        source = $Source
        output = $resolvedOutput
        asset_output = $resolvedAssetOutput
        session_count = $selected.Count
        next_cursor = $nextCursor
    } | ConvertTo-Json -Compress
} else {
    Write-Output (
        "Exported $($selected.Count) session(s) to $resolvedOutput; " +
        $(if ($resolvedAssetOutput) {
            "projects to $resolvedAssetOutput; "
        } else {
            ""
        }) +
        "next cursor $nextCursor"
    )
}
