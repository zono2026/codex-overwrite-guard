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

$texts = @($raw)
try {
    $json = $raw | ConvertFrom-Json
    Add-TextFromValue -Value $json -Texts ([ref]$texts)
} catch {
    # Hooks should be conservative but not fail just because Codex changes JSON shape.
}

$haystack = $texts -join "`n"
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

$riskyShellPattern = "(?i)\b(Remove-Item|Move-Item|Set-Content|Out-File|Copy-Item|rm|del|erase|mv)\b|(?m)(^|[^2])>{1,2}\s*[^&]"
$hasRiskyShellOperation = [regex]::IsMatch($haystack, $riskyShellPattern)
$hasBackupIntent = [regex]::IsMatch($haystack, "(?i)(\.bak\b|backup|before|original)")

if ($hasRiskyShellOperation -and -not $hasBackupIntent) {
    if (Test-ProtectedTargetMention $haystack) {
        $reasons += "shell command looked like it could overwrite, delete, move, or replace a protected source file without an obvious backup."
    } else {
        $reasons += "shell command uses file mutation syntax, but the target could not be inspected; failing closed."
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
