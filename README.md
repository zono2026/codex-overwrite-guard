# codex-overwrite-guard

A PreToolUse hook for [OpenAI Codex CLI](https://github.com/openai/codex) that blocks AI agents from overwriting or deleting source files without an explicit backup.

## Background

An AI agent (Codex) overwrote a production source file without making a backup first. The original file was lost. This hook was built to prevent that from happening again.

## What it blocks

| Operation | Example | Result |
|---|---|---|
| Delete + re-add same file | `*** Delete File: foo.csv` then `*** Add File: foo.csv` | Blocked |
| Move/replace via patch | `*** Move to: foo.csv` | Blocked |
| `Remove-Item`, `rm`, `del` on a user file | `Remove-Item Documents\foo.csv` | Blocked |
| Destructive shell op with unresolvable target | `Remove-Item $target` | Blocked (fail-closed) |
| Redirect overwrite on a protected path | `... > Documents\foo.csv` | Blocked |

## What it allows

| Operation | Example | Result |
|---|---|---|
| In-place edit via patch | `*** Update File: foo.csv` | Allowed |
| Backup copy with `.bak` suffix | `Copy-Item foo.csv foo.csv.bak_before_edit -Force` | Allowed |
| Operations in `.codex\`, `temp\`, `tmp\` | any path under those dirs | Allowed |

## Requirements

- Windows
- PowerShell 5.1 or later (built into Windows)
- [OpenAI Codex CLI](https://github.com/openai/codex) v0.1 or later

## Installation

1. Copy the validator script to your Codex config folder:

```powershell
Copy-Item prevent_source_overwrite.ps1 "$env:USERPROFILE\.codex\validators\"
```

2. Merge the hook definition into `~/.codex/hooks.json`.  
   If you don't have a `hooks.json` yet, copy it directly:

```powershell
Copy-Item hooks.json "$env:USERPROFILE\.codex\hooks.json"
```

   If you already have a `hooks.json`, add the `PreToolUse` entry manually:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|shell_command|functions\\.shell_command|apply_patch|Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\.codex\\validators\\prevent_source_overwrite.ps1\"",
            "timeout": 10,
            "statusMessage": "Checking source-file overwrite guard"
          }
        ]
      }
    ]
  }
}
```

3. Start a new Codex session and run `/hooks` to confirm `PreToolUse` shows **Active 1**.  
   No manual Trust step is required — hooks defined in `~/.codex/hooks.json` are trusted automatically.

## Running tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File validators\prevent_source_overwrite.tests.ps1
```

Expected output:

```
PASS blocks empty hook input: exit 2
PASS blocks apply_patch delete and add replacement via stdin: exit 2
PASS allows apply_patch update: exit 0
PASS blocks remove item against document: exit 2
PASS blocks remove item without inspectable target: exit 2
PASS allows same-folder backup copy: exit 0
```

## How it works

Codex calls this script as a PreToolUse hook before every tool execution. The hook receives the tool name and input as JSON on stdin. It:

1. Parses the JSON and flattens all string values into a single text block
2. Scans for dangerous `apply_patch` markers (`*** Delete File:`, `*** Move to:`)
3. Scans for destructive shell operations (`Remove-Item`, `rm`, `>`, etc.)
4. Checks for backup intent keywords (`.bak`, `backup`, `before`, `original`)
5. Exits with code `2` to block, `0` to allow
6. When in doubt, exits `2` (fail-closed)

## Limitations

- Windows only (PowerShell). A cross-platform Python version is not yet available.
- The `matcher` field must cover all tool names Codex uses for file I/O. If Codex adds new tool names in a future version, update `hooks.json` accordingly.
- Hook payload format is based on Codex v0.136.0. If the JSON structure changes in a future version, the script may need updating.

## License

MIT
