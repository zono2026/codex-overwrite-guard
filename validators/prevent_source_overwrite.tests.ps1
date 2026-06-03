$ErrorActionPreference = "Stop"

$validator = Join-Path $PSScriptRoot "prevent_source_overwrite.ps1"

$tests = @(
    @{
        Name = "blocks empty hook input"
        Payload = $null
        ExpectedExitCode = 2
    },
    @{
        Name = "blocks apply_patch delete and add replacement via stdin"
        Payload = @{
            tool = "apply_patch"
            input = "*** Delete File: Documents/foo.csv`n*** Add File: Documents/foo.csv"
        }
        ExpectedExitCode = 2
    },
    @{
        Name = "allows apply_patch update"
        Payload = @{
            tool = "apply_patch"
            input = "*** Update File: Documents/foo.csv`n@@`n-old`n+new"
        }
        ExpectedExitCode = 0
    },
    @{
        Name = "blocks remove item against document"
        Payload = @{
            tool = "Bash"
            command = "Remove-Item -LiteralPath C:\Users\OSKCLT4740\Documents\foo.csv"
        }
        ExpectedExitCode = 2
    },
    @{
        Name = "blocks remove item without inspectable target"
        Payload = @{
            tool = "Bash"
            command = "Remove-Item `$target"
        }
        ExpectedExitCode = 2
    },
    @{
        Name = "allows same-folder backup copy"
        Payload = @{
            tool = "Bash"
            command = "Copy-Item -LiteralPath C:\Users\OSKCLT4740\Documents\foo.csv -Destination C:\Users\OSKCLT4740\Documents\foo.csv.bak_before_edit -Force"
        }
        ExpectedExitCode = 0
    },
    @{
        Name = "blocks copy-item overwrite without backup name"
        Payload = @{
            tool = "Bash"
            command = "Copy-Item -LiteralPath C:\Users\OSKCLT4740\Documents\foo.csv -Destination C:\Users\OSKCLT4740\Documents\bar.csv"
        }
        ExpectedExitCode = 2
    },
    @{
        Name = "allows copy-item to backup name without force"
        Payload = @{
            tool = "Bash"
            command = "Copy-Item -LiteralPath C:\Users\OSKCLT4740\Documents\foo.csv -Destination C:\Users\OSKCLT4740\Documents\foo_backup.csv"
        }
        ExpectedExitCode = 0
    }
)

$failed = $false
foreach ($test in $tests) {
    if ($null -eq $test.Payload) {
        $inputJson = ""
    } else {
        $inputJson = $test.Payload | ConvertTo-Json -Compress
    }
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $inputJson | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validator *> $null
    $actual = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($actual -ne $test.ExpectedExitCode) {
        Write-Output "FAIL $($test.Name): expected $($test.ExpectedExitCode), got $actual"
        $failed = $true
    } else {
        Write-Output "PASS $($test.Name): exit $actual"
    }
}

if ($failed) {
    exit 1
}

exit 0
