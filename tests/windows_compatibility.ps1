$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sessionScript = Join-Path (
    Join-Path $repositoryRoot "scripts"
) "export_sessions_windows.ps1"
$mcpScript = Join-Path (
    Join-Path $repositoryRoot "scripts"
) "export_mcp_windows.ps1"

function Assert-True {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Import-FunctionFromScript {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Name
    )

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref] $tokens,
        [ref] $errors
    )
    if ($errors.Count -gt 0) {
        throw "PowerShell parse failed: $Path"
    }
    $matches = @(
        $ast.FindAll(
            {
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] `
                    -and $node.Name -ceq $Name
            },
            $true
        )
    )
    if ($matches.Count -ne 1) {
        throw "Expected one function named '$Name' in $Path"
    }
    $body = $matches[0].Body.Extent.Text
    $body = $body.Substring(1, $body.Length - 2)
    Set-Item `
        -Path "Function:\script:$Name" `
        -Value ([scriptblock]::Create($body))
}

Import-FunctionFromScript -Path $sessionScript -Name "Resolve-OutputPath"
Import-FunctionFromScript -Path $sessionScript -Name "Test-SameOutputPath"
Import-FunctionFromScript `
    -Path $sessionScript `
    -Name "ConvertTo-TimestampMilliseconds"
Import-FunctionFromScript `
    -Path $sessionScript `
    -Name "Sort-SessionsByUpdatedAt"
Import-FunctionFromScript -Path $sessionScript -Name "Select-Sessions"
Import-FunctionFromScript `
    -Path $sessionScript `
    -Name "Test-WorkBuddyMetaMessage"
Import-FunctionFromScript `
    -Path $sessionScript `
    -Name "Get-WorkBuddyVisibleUserQueries"
Import-FunctionFromScript `
    -Path $sessionScript `
    -Name "Convert-WorkBuddyShareHtmlLinks"

$relativePath = Resolve-OutputPath -Path "windows-test.jsonl"
Assert-True `
    -Condition ([IO.Path]::IsPathRooted($relativePath)) `
    -Message "Relative output path was not resolved"
Assert-True `
    -Condition (Test-SameOutputPath `
        "C:\Temp\Sessions.jsonl" `
        "c:\temp\sessions.jsonl") `
    -Message "Windows path comparison must ignore case"
Assert-True `
    -Condition (-not (Test-SameOutputPath `
        "C:\Temp\sessions.jsonl" `
        "C:\Temp\assets.jsonl")) `
    -Message "Different output paths were treated as equal"

$taskNotification = "<task-notification>completed</task-notification>"
$metaMessage = [pscustomobject]@{
    role = "user"
    content = @(
        [pscustomobject]@{ type = "input_text"; text = $taskNotification }
    )
    providerData = [pscustomobject]@{ isMeta = $true }
}
$userMessage = [pscustomobject]@{
    role = "user"
    content = @(
        [pscustomobject]@{ type = "input_text"; text = $taskNotification }
    )
    providerData = [pscustomobject]@{}
}
Assert-True `
    -Condition (Test-WorkBuddyMetaMessage -Record $metaMessage) `
    -Message "WorkBuddy internal meta message was not excluded"
Assert-True `
    -Condition (-not (Test-WorkBuddyMetaMessage -Record $userMessage)) `
    -Message "User-authored notification text was incorrectly excluded"

$nestedUserQuery = (
    "context before reminder" +
    "<context-envelope><user_query>" +
    "You MUST follow these steps in order" +
    "</user_query></context-envelope>" +
    "<system-reminder><user_query>ignore this too</user_query>" +
    "</system-reminder>" +
    "<user_query>visible request</user_query>"
)
$visibleQueries = @(
    Get-WorkBuddyVisibleUserQueries -Text $nestedUserQuery
)
Assert-True `
    -Condition (
        $visibleQueries.Count -eq 1 -and
        $visibleQueries[0] -ceq "visible request"
    ) `
    -Message "Embedded system reminder query leaked into visible user text"

$namedShareHtml =
    "@share-html#ColorHarbor%20%E9%85%8D%E8%89%B2%E6%94%B6%E8%97%8F%E5%BA%93.html:" +
    "https://static.workbuddy.cn/workbuddy/playbook/cases/" +
    "code-colorharbor-palette/output.html 44"
$namedLabel = "ColorHarbor " +
    [char]0x914D + [char]0x8272 + [char]0x6536 +
    [char]0x85CF + [char]0x5E93 + ".html"
$namedShareHtmlExpected =
    "[$namedLabel](https://static.workbuddy.cn/workbuddy/playbook/cases/" +
    "code-colorharbor-palette/output.html) 44"
Assert-True `
    -Condition (
        (Convert-WorkBuddyShareHtmlLinks -Text $namedShareHtml) -ceq
        $namedShareHtmlExpected
    ) `
    -Message "Named WorkBuddy shared HTML link conversion failed"

$bareShareHtml =
    "See @share-html:https://example.invalid/files/report%20final.html" +
    "?mode=1#top after"
$bareShareHtmlExpected =
    "See [report final.html](https://example.invalid/files/" +
    "report%20final.html?mode=1#top) after"
Assert-True `
    -Condition (
        (Convert-WorkBuddyShareHtmlLinks -Text $bareShareHtml) -ceq
        $bareShareHtmlExpected
    ) `
    -Message "Bare WorkBuddy shared HTML link conversion failed"

$sessions = @(
    [pscustomobject]@{
        sessionId = "created-first-updated-last"
        startedAt = 1000
        updatedAt = 5000
    },
    [pscustomobject]@{
        sessionId = "created-last-updated-first"
        startedAt = 3000
        updatedAt = 2000
    }
)
$sortedSessions = @(Sort-SessionsByUpdatedAt -Sessions $sessions)
Assert-True `
    -Condition (
        $sortedSessions[0].sessionId -ceq "created-last-updated-first" -and
        $sortedSessions[1].sessionId -ceq "created-first-updated-last"
    ) `
    -Message "Sessions were not ordered by last update timestamp"

$All = $false
$SessionId = @()
$Title = @()
$Cursor = "2000"
$cursorSpecified = $true
$incrementalSessions = @(Select-Sessions -Sessions $sortedSessions)
Assert-True `
    -Condition (
        $incrementalSessions.Count -eq 1 -and
        $incrementalSessions[0].sessionId -ceq "created-last-updated-first"
    ) `
    -Message "Incremental cursor did not use session creation timestamp"

$temporaryRoot = Join-Path (
    [IO.Path]::GetTempPath()
) "migrate-doubao-assets-test-$([Guid]::NewGuid().ToString('N'))"
$sourcePath = Join-Path $temporaryRoot "mcp.json"
$outputPath = Join-Path $temporaryRoot "result.jsonl"
$utf8 = [Text.UTF8Encoding]::new($false, $true)

try {
    [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    $configuration = [ordered]@{
        mcpServers = [ordered]@{
            "server-a" = [ordered]@{
                url = "https://example.invalid/路径"
                ignored = "value"
            }
            "server-b" = [ordered]@{
                url = "https://example.invalid/b"
            }
        }
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($sourcePath, $configuration, $utf8)
    [IO.File]::WriteAllText(
        $outputPath,
        "{`"item_type`":`"agents_md`",`"agents_md_config`":{`"content`":`"keep`"}}`n",
        $utf8
    )

    $result = & $mcpScript `
        -Source qwenwork `
        -SourcePath $sourcePath `
        -Output $outputPath `
        -Json |
            ConvertFrom-Json
    Assert-True `
        -Condition ($result.record_count -eq 2) `
        -Message "Unexpected MCP record count"

    $text = [IO.File]::ReadAllText($outputPath, $utf8)
    Assert-True `
        -Condition ($text.EndsWith("`n") -and -not $text.Contains("`r")) `
        -Message "MCP package must use LF-delimited UTF-8 JSONL"
    $records = @(
        $text.Substring(0, $text.Length - 1).Split("`n") |
            ForEach-Object { $_ | ConvertFrom-Json }
    )
    Assert-True `
        -Condition ($records.Count -eq 3) `
        -Message "MCP package did not preserve the existing record"
    Assert-True `
        -Condition ($records[0].item_type -ceq "agents_md") `
        -Message "Existing record order changed"
    Assert-True `
        -Condition (
            $records[1].mcp_config.streamable_http.url -ceq
                "https://example.invalid/路径"
        ) `
        -Message "UTF-8 MCP URL did not round-trip"

    $conflictRejected = $false
    try {
        & $mcpScript `
            -Source qwenwork `
            -SourcePath $sourcePath `
            -Output $outputPath |
                Out-Null
    } catch {
        $conflictRejected = $true
    }
    Assert-True `
        -Condition $conflictRejected `
        -Message "Existing MCP collection was replaced without approval"

    & $mcpScript `
        -Source qwenwork `
        -SourcePath $sourcePath `
        -Output $outputPath `
        -Name "server-b" `
        -OverwriteCollection |
            Out-Null
    $updatedText = [IO.File]::ReadAllText($outputPath, $utf8)
    $updated = @(
        $updatedText.Substring(0, $updatedText.Length - 1).Split("`n") |
            ForEach-Object { $_ | ConvertFrom-Json }
    )
    $updatedMcp = @(
        $updated | Where-Object { $_.item_type -ceq "mcp" }
    )
    Assert-True `
        -Condition (
            $updatedMcp.Count -eq 1 -and
            $updatedMcp[0].mcp_config.name -ceq "server-b"
        ) `
        -Message "MCP collection replacement failed"

    $connectorsRoot = Join-Path $temporaryRoot "connectors"
    $skillRoot = Join-Path $connectorsRoot "skills\connector-alpha"
    $guidRoot = Join-Path (
        $connectorsRoot
    ) "11111111-2222-3333-4444-555555555555"
    [IO.Directory]::CreateDirectory($skillRoot) | Out-Null
    [IO.Directory]::CreateDirectory($guidRoot) | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $skillRoot "SKILL.md"),
        "---`nname: connector-alpha`n---`n",
        $utf8
    )
    $workBuddyConfiguration = [ordered]@{
        mcpServers = [ordered]@{
            "connector:alpha" = [ordered]@{
                url = "https://example.invalid/workbuddy"
            }
        }
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText(
        (Join-Path $guidRoot "mcp.json"),
        $workBuddyConfiguration,
        $utf8
    )
    $workBuddyOutput = Join-Path $temporaryRoot "workbuddy.jsonl"
    $workBuddyResult = & $mcpScript `
        -Source workbuddy `
        -SourcePath $connectorsRoot `
        -Output $workBuddyOutput `
        -Json |
            ConvertFrom-Json
    Assert-True `
        -Condition (
            $workBuddyResult.record_count -eq 1 -and
            $workBuddyResult.names[0] -ceq "alpha"
        ) `
        -Message "WorkBuddy MCP configuration resolution failed"
} finally {
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

"Windows compatibility tests: OK"
