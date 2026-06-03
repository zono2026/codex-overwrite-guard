param(
    [string]$InputJson
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($InputJson)) {
    $raw = [Console]::In.ReadToEnd()
} else {
    $raw = $InputJson
}

if ([string]::IsNullOrWhiteSpace($raw)) {
    [Console]::Error.WriteLine("Source overwrite guard received no hook input; failing closed.")
    [Console]::Error.WriteLine("Codex hooks must provide tool-call details on stdin for this guard to evaluate the operation.")
    exit 2
}

function Add-TextFromValue {
    param(
        [Parameter(Mandatory = $false)] $Value,
        [ref] $Texts
    )

    if ($null -eq $Value) {
        return
    }

    if ($Value -is [string]) {
        $Texts.Value += $Value
        return
    }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            $Texts.Value += [string]$key
            Add-TextFromValue -Value $Value[$key] -Texts $Texts
        }
        return
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        foreach ($item in $Value) {
            Add-TextFromValue -Value $item -Texts $Texts
        }
        return
    }

    $props = $Value.PSObject.Properties
    if ($props.Count -gt 0) {
        foreach ($prop in $props) {
            $Texts.Value += $prop.Name
            Add-TextFromValue -Value $prop.Value -Texts $Texts
        }
        return
    }

    $Texts.Value += [string]$Value
}

function Normalize-PathText {
    param([string]$PathText)

    if ([string]::IsNullOrWhiteSpace($PathText)) {
        return ""
    }

    return ($PathText.Trim().Trim('"').Trim("'") -replace "^\\\\\?\\", "" -replace "/", "\").ToLowerInvariant()
}

function Test-ExemptPath {
    param([string]$PathText)

    $path = Normalize-PathText $PathText
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $false
    }

    return (
        $path -match "\\\.codex\\" -or
        $path -match "\\appdata\\local\\temp\\" -or
        $path -match "\\tmp\\" -or
        $path -match "(^|[\\._-])(bak|backup|original|before)([\\._-]|$)"
    )
}

function Test-BackupDestination {
    param([string]$Token)

    $path = Normalize-PathText $Token
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $false
    }
    if ($path -notmatch "\\" -and $path -notmatch "\.") {
        return $false
    }
    return $path -match "(^|[\\._-])(bak|backup|original|before)([\\._-]|$)"
}

function Get-AllCopyDestinations {
    param([string]$Text)

    $destinations = @()
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $destinations
    }

    # Find all copy commands, scoped to their segment (delimited by ; | & newline).
    # Copy-Item/cpi are tried first (via alternation order) to prevent
    # 'copy' from matching inside 'Copy-Item'.
    $copyPattern = [regex]::new('(?i)\b(?:Copy-Item|cpi)\b\s*([^;|&\n]*)|\b(?:cp|copy)\b\s*([^;|&\n]*)')
    $copyMatches = $copyPattern.Matches($Text)

    foreach ($m in $copyMatches) {
        if ($m.Groups[1].Success) {
            $args = $m.Groups[1].Value
        } else {
            $args = $m.Groups[2].Value
        }

        if ($args -match '(?i)-(Destination|Dest|D)\s+(\S+)') {
            $destinations += $Matches[2]
            continue
        }

        $tokens = @($args -split '\s+' | Where-Object { $_ })
        $positionals = @($tokens | Where-Object { -not $_.StartsWith('-') })
        if ($positionals.Count -ge 2) {
            $destinations += $positionals[$positionals.Count - 1]
        } else {
            $destinations += $null
        }
    }

    return $destinations
}

function Test-ProtectedTargetMention {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $normalized = Normalize-PathText $Text

    if ($normalized -match "\\\.codex\\") {
        return $false
    }

    return (
        $normalized -match "\\users\\[^\\]+\\(documents|desktop|downloads|onedrive)\\" -or
        $normalized -match "\.(csv|tsv|xlsx|xls|xlsm|docx|doc|pdf|txt|md|json|toml|yaml|yml|ps1|py|js|ts|tsx|jsx|html|css|sql)(\s|`"|`'|$)"
    )
}

function Get-AllCommandTexts {
    param($Data)

    if ($null -eq $Data) { return @() }

    $results = @()
    # Direct 'command' field (Bash tool)
    if ($Data.PSObject.Properties['command'] -and $Data.command -is [string]) {
        $results += $Data.command
    }
    # Nested tool_input.command
    if ($Data.PSObject.Properties['tool_input'] -and $null -ne $Data.tool_input) {
        $ti = $Data.tool_input
        if ($ti.PSObject.Properties['command'] -and $ti.command -is [string]) {
            if ($results -notcontains $ti.command) {
                $results += $ti.command
            }
        }
    }
    # 'input' field (apply_patch, etc.) — lowest priority
    if ($Data.PSObject.Properties['input'] -and $Data.input -is [string]) {
        if ($results -notcontains $Data.input) {
            $results += $Data.input
        }
    }
    return $results
}

$texts = @($raw)
$jsonParsed = $false
$commandText = $null
try {
    $json = $raw | ConvertFrom-Json
    $jsonParsed = $true
    Add-TextFromValue -Value $json -Texts ([ref]$texts)
    $commandTexts = @(Get-AllCommandTexts $json)
} catch {
    # Hooks should be conservative but not fail just because Codex changes JSON shape.
}

$haystack = $texts -join "`n"
# For copy destination extraction, use only actual command strings.
# If JSON parsed but no command fields found, use empty string (fail closed).
# Fall back to haystack only if JSON parse itself failed (raw text input).
if ($commandTexts.Count -gt 0) {
    $copySources = $commandTexts
} elseif ($jsonParsed) {
    $copySources = @("")
} else {
    $copySources = @($haystack)
}
$reasons = @()

$deleteMatches = [regex]::Matches($haystack, "(?m)^\*\*\* Delete File:\s*(.+?)\s*$")
foreach ($match in $deleteMatches) {
    $path = $match.Groups[1].Value
    if (-not (Test-ExemptPath $path)) {
        $reasons += "apply_patch attempted to delete a file: $path"
    }
}

$moveMatches = [regex]::Matches($haystack, "(?m)^\*\*\* Move to:\s*(.+?)\s*$")
foreach ($match in $moveMatches) {
    $path = $match.Groups[1].Value
    if (-not (Test-ExemptPath $path)) {
        $reasons += "apply_patch attempted to move/replace a file: $path"
    }
}

$deletePaths = @()
foreach ($match in $deleteMatches) {
    $deletePaths += (Normalize-PathText $match.Groups[1].Value)
}

$addMatches = [regex]::Matches($haystack, "(?m)^\*\*\* Add File:\s*(.+?)\s*$")
foreach ($match in $addMatches) {
    $addPath = Normalize-PathText $match.Groups[1].Value
    if (($deletePaths -contains $addPath) -and -not (Test-ExemptPath $addPath)) {
        $reasons += "apply_patch attempted to replace a file by deleting and re-adding it: $($match.Groups[1].Value)"
    }
}

$destructivePattern = "(?i)\b(Remove-Item|Move-Item|Set-Content|Out-File|New-Item|rm|del|erase|mv|ri|mi|sc|ni)\b|>{1,2}\s*(?!&)\S"
$hasDestructiveOp = [regex]::IsMatch($haystack, $destructivePattern)

$copyPattern = "(?i)\b(Copy-Item|cp|copy|cpi)\b"
$hasCopyOp = [regex]::IsMatch($haystack, $copyPattern)

if ($hasDestructiveOp) {
    if (Test-ProtectedTargetMention $haystack) {
        $reasons += "shell command contains a destructive operation targeting a protected source file."
    } else {
        $reasons += "shell command uses destructive syntax, but the target could not be inspected; failing closed."
    }
}

if ($hasCopyOp -and -not $hasDestructiveOp) {
    $allDests = @()
    foreach ($src in $copySources) {
        $allDests += @(Get-AllCopyDestinations $src)
    }

    $blocked = $false
    if ($allDests.Count -eq 0) {
        $blocked = $true
    } else {
        foreach ($dest in $allDests) {
            if ($null -eq $dest -or -not (Test-BackupDestination $dest)) {
                $blocked = $true
                break
            }
        }
    }

    if ($blocked) {
        if (Test-ProtectedTargetMention $haystack) {
            $reasons += "copy command targets a protected file without a backup-named destination."
        } else {
            $reasons += "copy command target could not be inspected; failing closed."
        }
    }
}

if ($reasons.Count -gt 0) {
    [Console]::Error.WriteLine("Source overwrite guard blocked this tool call.")
    foreach ($reason in $reasons) {
        [Console]::Error.WriteLine("- $reason")
    }
    [Console]::Error.WriteLine("Create a same-folder backup or a clearly named new output file before touching the original. Modify the original only after explicit user confirmation.")
    exit 2
}

exit 0
