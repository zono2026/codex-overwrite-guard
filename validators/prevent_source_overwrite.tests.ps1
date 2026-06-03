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
            command = "Remove-Item -LiteralPath C:\Users\testuser\Documents\foo.csv"
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
            command = "Copy-Item -LiteralPath C:\Users\testuser\Documents\foo.csv -Destination C:\Users\testuser\Documents\foo.csv.bak_before_edit -Force"
        }
        ExpectedExitCode = 0
    },
    @{
        Name = "blocks copy-item overwrite without backup name"
        Payload = @{
            tool = "Bash"
            command = "Copy-Item -LiteralPath C:\Users\testuser\Documents\foo.csv -Destination C:\Users\testuser\Documents\bar.csv"
        }
        ExpectedExitCode = 2
    },
    @{
        Name = "allows copy-item to backup name without force"
        Payload = @{
            tool = "Bash"
            command = "Copy-Item -LiteralPath C:\Users\testuser\Documents\foo.csv -Destination C:\Users\testuser\Documents\foo_backup.csv"
        }
        ExpectedExitCode = 0
    },
    @{
        Name = "blocks rm even when backup keyword appears in text"
        Payload = @{
            tool = "Bash"
            command = "echo 'creating backup' ; rm C:\Users\testuser\Documents\foo.csv"
        }
        ExpectedExitCode = 2
    },
    @{
        Name = "blocks ri alias against document"
        Payload = @{
            tool = "Bash"
            command = "ri C:\Users\testuser\Documents\foo.csv"
        }
        ExpectedExitCode = 2
    },
    @{
        Name = "blocks cp without backup destination"
        Payload = @{
            tool = "Bash"
            command = "cp C:\Users\testuser\Documents\new.py C:\Users\testuser\Documents\foo.py"
        }
        ExpectedExitCode = 2
    },
    @{
        Name = "allows cp to backup destination"
        Payload = @{
            tool = "Bash"
            command = "cp C:\Users\testuser\Documents\foo.py C:\Users\testuser\Documents\foo_backup.py"
        }
        ExpectedExitCode = 0
    },
    @{
        Name = "blocks copy-item when source has backup name but destination does not"
        Payload = @{
            tool = "Bash"
            command = "Copy-Item C:\Users\testuser\Documents\foo_backup.csv -Destination C:\Users\testuser\Documents\bar.csv"
        }
        ExpectedExitCode = 2
    },
    @{
        Name = "allows copy-item with -Destination backup name"
        Payload = @{
            tool = "Bash"
            command = "Copy-Item -LiteralPath C:\Users\testuser\Documents\foo.csv -Destination C:\Users\testuser\Documents\foo_backup.csv"
        }
        ExpectedExitCode = 0
    },
    @{
        Name = "allows copy-item with -Dest shorthand backup name"
        Payload = @{
            tool = "Bash"
            command = "Copy-Item -LiteralPath C:\Users\testuser\Documents\foo.csv -Dest C:\Users\testuser\Documents\foo_backup.csv"
        }
        ExpectedExitCode = 0
    },
    @{
        Name = "blocks copy when fake backup destination is in non-command field"
        Payload = @{
            tool = "Bash"
            note = "pretend -Destination C:\Users\testuser\Documents\foo_backup.csv"
            command = "Copy-Item -LiteralPath C:\Users\testuser\Documents\foo.csv -Destination C:\Users\testuser\Documents\bar.csv"
        }
        ExpectedExitCode = 2
    },
    @{
        Name = "blocks unsafe copy in tool_input.command when input has fake backup"
        Payload = @{
            tool = "Bash"
            input = "Copy-Item -Destination C:\Users\testuser\Documents\foo_backup.csv"
            tool_input = @{
                command = "Copy-Item C:\Users\testuser\Documents\foo.csv -Destination C:\Users\testuser\Documents\bar.csv"
            }
        }
        ExpectedExitCode = 2
    },
    @{
        Name = "blocks copy when fake -Destination precedes real copy command"
        Payload = @{
            tool = "Bash"
            command = "Write-Output `"-Destination C:\Users\testuser\Documents\foo_backup.csv`"; Copy-Item C:\Users\testuser\Documents\foo.csv -Destination C:\Users\testuser\Documents\bar.csv"
        }
        ExpectedExitCode = 2
    },
    @{
        Name = "blocks when first copy is safe but second copy is unsafe"
        Payload = @{
            tool = "Bash"
            command = "Copy-Item C:\Users\testuser\Documents\foo.csv -Destination C:\Users\testuser\Documents\foo_backup.csv; Copy-Item C:\Users\testuser\Documents\foo.csv -Destination C:\Users\testuser\Documents\bar.csv"
        }
        ExpectedExitCode = 2
    },
    @{
        Name = "blocks stderr redirect to file"
        Payload = @{
            tool = "Bash"
            command = "somecmd 2> C:\Users\testuser\Documents\error.log"
        }
        ExpectedExitCode = 2
    },
    @{
        Name = "allows stderr merge to stdout"
        Payload = @{
            tool = "Bash"
            command = "somecmd 2>&1 | grep pattern"
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
