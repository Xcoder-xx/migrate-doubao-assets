[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("qwenwork", "workbuddy")]
    [string] $Source,

    [string[]] $Name = @(),
    [string] $SourcePath,
    [string] $Output,
    [switch] $OverwriteCollection,
    [switch] $Json
)

$ErrorActionPreference = "Stop"
$Utf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Read-StrictUtf8 {
    param([Parameter(Mandatory)][string] $Path)
    return [IO.File]::ReadAllText($Path, $Utf8)
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

function Read-McpConfiguration {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "MCP configuration not found: $Path"
    }
    $value = Read-StrictUtf8 -Path $Path | ConvertFrom-Json
    if (
        $null -eq $value -or
        $value -is [array] -or
        $null -eq $value.mcpServers -or
        $value.mcpServers -isnot [pscustomobject]
    ) {
        throw "Invalid mcpServers object: $Path"
    }
    return $value
}

function Get-ExactProperty {
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)][string] $PropertyName
    )

    return @(
        $Object.PSObject.Properties |
            Where-Object { $_.Name -ceq $PropertyName }
    )
}

function Select-ExactNames {
    param(
        [Parameter(Mandatory)][string[]] $AvailableNames,
        [string[]] $RequestedNames = @(),
        [Parameter(Mandatory)][string] $Label
    )

    if ($RequestedNames.Count -eq 0) {
        return @($AvailableNames)
    }
    $selected = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($requestedName in $RequestedNames) {
        if (-not $AvailableNames.Contains($requestedName)) {
            throw "${Label} not found: $requestedName"
        }
        if ($seen.Add($requestedName)) {
            $selected.Add($requestedName)
        }
    }
    return @($selected.ToArray() | Sort-Object)
}

function New-McpItem {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)] $Server
    )

    if (
        $null -eq $Server -or
        $Server -isnot [pscustomobject] -or
        $Server.url -isnot [string] -or
        [string]::IsNullOrEmpty($Server.url)
    ) {
        throw "MCP server URL is missing or invalid: $Name"
    }
    return [ordered]@{
        item_type = "mcp"
        mcp_config = [ordered]@{
            unique_id = $Name
            name = $Name
            transport_type = 2
            streamable_http = [ordered]@{ url = $Server.url }
        }
    }
}

function Get-WorkBuddyMcpItems {
    param(
        [string[]] $RequestedNames = @(),
        [string] $ConnectorsRoot
    )

    if ([string]::IsNullOrWhiteSpace($ConnectorsRoot)) {
        $ConnectorsRoot = Join-Path $HOME ".workbuddy\connectors"
    }
    $skillsRoot = Join-Path $connectorsRoot "skills"
    if (-not (Test-Path -LiteralPath $skillsRoot -PathType Container)) {
        throw "WorkBuddy connector skills directory not found: $skillsRoot"
    }

    $availableNames = @(
        Get-ChildItem -LiteralPath $skillsRoot -Directory |
            Where-Object {
                $_.Name.StartsWith(
                    "connector-",
                    [StringComparison]::Ordinal
                ) -and
                (Test-Path -LiteralPath (
                    Join-Path $_.FullName "SKILL.md"
                ) -PathType Leaf)
            } |
            ForEach-Object { $_.Name } |
            Sort-Object
    )
    $selectedNames = @(
        Select-ExactNames `
            -AvailableNames $availableNames `
            -RequestedNames $RequestedNames `
            -Label "Connector skill"
    )
    if ($selectedNames.Count -eq 0) {
        throw "No eligible WorkBuddy connector skills found"
    }

    $guidPattern =
        "^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
    $guidConfigurations = @(
        Get-ChildItem -LiteralPath $connectorsRoot -Directory |
            Where-Object { $_.Name -match $guidPattern } |
            Sort-Object -Property Name |
            ForEach-Object {
                $path = Join-Path $_.FullName "mcp.json"
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    [pscustomobject]@{
                        Path = $path
                        Value = Read-McpConfiguration -Path $path
                    }
                }
            }
    )

    $defaultPath = Join-Path $connectorsRoot "default\mcp.json"
    $defaultConfiguration = $null
    $items = [Collections.Generic.List[object]]::new()
    foreach ($skillName in $selectedNames) {
        $serverKey =
            "connector:" + $skillName.Substring("connector-".Length)
        $matches = @(
            $guidConfigurations |
                Where-Object {
                    @(
                        Get-ExactProperty `
                            -Object $_.Value.mcpServers `
                            -PropertyName $serverKey
                    ).Count -eq 1
                }
        )
        if ($matches.Count -gt 1) {
            throw "Ambiguous MCP server key: $serverKey"
        }

        if ($matches.Count -eq 1) {
            $property = @(
                Get-ExactProperty `
                    -Object $matches[0].Value.mcpServers `
                    -PropertyName $serverKey
            )[0]
        } else {
            if ($null -eq $defaultConfiguration) {
                $defaultConfiguration =
                    Read-McpConfiguration -Path $defaultPath
            }
            $properties = @(
                Get-ExactProperty `
                    -Object $defaultConfiguration.mcpServers `
                    -PropertyName $serverKey
            )
            if ($properties.Count -ne 1) {
                throw "MCP server key not found: $serverKey"
            }
            $property = $properties[0]
        }
        $items.Add(
            (New-McpItem `
                -Name $serverKey.Substring("connector:".Length) `
                -Server $property.Value)
        )
    }
    return $items.ToArray()
}

function Get-QwenWorkMcpItems {
    param(
        [string[]] $RequestedNames = @(),
        [string] $ConfigurationPath
    )

    if ([string]::IsNullOrWhiteSpace($ConfigurationPath)) {
        $ConfigurationPath = Join-Path $HOME ".qwenworkcn\mcp.json"
    }
    $configuration = Read-McpConfiguration -Path $configurationPath
    $availableNames = @(
        $configuration.mcpServers.PSObject.Properties |
            ForEach-Object { $_.Name } |
            Sort-Object
    )
    $selectedNames = @(
        Select-ExactNames `
            -AvailableNames $availableNames `
            -RequestedNames $RequestedNames `
            -Label "MCP server"
    )
    if ($selectedNames.Count -eq 0) {
        throw "No QwenWork MCP servers found"
    }

    return @(
        foreach ($serverName in $selectedNames) {
            $property = @(
                Get-ExactProperty `
                    -Object $configuration.mcpServers `
                    -PropertyName $serverName
            )[0]
            New-McpItem -Name $serverName -Server $property.Value
        }
    )
}

function Read-AssetRecords {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    $text = Read-StrictUtf8 -Path $Path
    if ($text.Length -eq 0) {
        return @()
    }
    if (-not $text.EndsWith("`n")) {
        throw "JSONL package must end with LF: $Path"
    }

    $records = [Collections.Generic.List[object]]::new()
    $lines = $text.Substring(0, $text.Length - 1).Split("`n")
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
        $records.Add([pscustomobject]@{ Raw = $line; Value = $value })
    }
    return $records.ToArray()
}

function Write-McpPackage {
    param(
        [Parameter(Mandatory)][object[]] $Items,
        [Parameter(Mandatory)][string] $Path
    )

    $records = @(Read-AssetRecords -Path $Path)
    $existingMcp = @(
        $records | Where-Object { $_.Value.item_type -ceq "mcp" }
    )
    if ($existingMcp.Count -gt 0 -and -not $OverwriteCollection) {
        throw "MCP collection already exists in $Path"
    }
    $otherLines = @(
        $records |
            Where-Object { $_.Value.item_type -cne "mcp" } |
            ForEach-Object { $_.Raw }
    )
    $itemLines = @(
        $Items | ForEach-Object {
            $_ | ConvertTo-Json -Depth 6 -Compress
        }
    )

    $candidateLines = [Collections.Generic.List[string]]::new()
    $inserted = $false
    foreach ($record in $records) {
        if ($record.Value.item_type -ceq "mcp") {
            if (-not $inserted) {
                foreach ($line in $itemLines) {
                    $candidateLines.Add($line)
                }
                $inserted = $true
            }
        } else {
            $candidateLines.Add($record.Raw)
        }
    }
    if (-not $inserted) {
        foreach ($line in $itemLines) {
            $candidateLines.Add($line)
        }
    }

    $candidate = [string]::Join("`n", $candidateLines) + "`n"
    $destinationPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($destinationPath)
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporaryPath = "$destinationPath.tmp.$PID"
    try {
        [IO.File]::WriteAllText($temporaryPath, $candidate, $Utf8)
        $validated = Read-StrictUtf8 -Path $temporaryPath
        $validatedRecords = @(Read-AssetRecords -Path $temporaryPath)
        $validatedMcp = @(
            $validatedRecords |
                Where-Object { $_.Value.item_type -ceq "mcp" }
        )
        $validatedOtherLines = @(
            $validatedRecords |
                Where-Object { $_.Value.item_type -cne "mcp" } |
                ForEach-Object { $_.Raw }
        )
        if (
            $validated -cne $candidate -or
            $validatedMcp.Count -ne $Items.Count -or
            [string]::Join("`n", $validatedOtherLines) -cne
                [string]::Join("`n", $otherLines)
        ) {
            throw "JSONL MCP collection validation failed: $Path"
        }
        for ($index = 0; $index -lt $Items.Count; $index++) {
            $expected = $Items[$index].mcp_config
            $actual = $validatedMcp[$index].Value.mcp_config
            if (
                $actual.unique_id -cne $expected.unique_id -or
                $actual.name -cne $expected.name -or
                $actual.unique_id -cne $actual.name -or
                $actual.transport_type -ne 2 -or
                $actual.streamable_http.url -cne
                    $expected.streamable_http.url
            ) {
                throw "JSONL MCP record validation failed: $Path"
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
    return $destinationPath
}

$items = @(
    if ($Source -ceq "workbuddy") {
        Get-WorkBuddyMcpItems `
            -RequestedNames $Name `
            -ConnectorsRoot $SourcePath
    } else {
        Get-QwenWorkMcpItems `
            -RequestedNames $Name `
            -ConfigurationPath $SourcePath
    }
)
$resolvedOutput = if ($Output) {
    $Output
} else {
    Join-Path $HOME "Downloads\$Source-import.jsonl"
}
$writtenPath = Write-McpPackage -Items $items -Path $resolvedOutput
$names = @($items | ForEach-Object { $_.mcp_config.name })

if ($Json) {
    [ordered]@{
        source = $Source
        output = $writtenPath
        item_type = "mcp"
        record_count = $items.Count
        names = $names
    } | ConvertTo-Json -Depth 4 -Compress
} else {
    "Exported $($items.Count) MCP server(s) to $writtenPath"
}
