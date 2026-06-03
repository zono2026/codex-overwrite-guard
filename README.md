# codex-overwrite-guard

A PreToolUse hook for [OpenAI Codex CLI](https://github.com/openai/codex) and [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that blocks AI agents from overwriting or deleting source files without an explicit backup.

## Background

An AI agent (Codex) overwrote a production source file without making a backup first. The original file was lost. This hook was built to prevent that from happening again.

## Expected Agent Behavior

When the agent attempts a destructive overwrite, the hook blocks it. A well-behaved agent will self-correct and switch to a safe method.

**Example output:**

```
Tool execution failed: exit code 2
  Source overwrite guard blocked this tool call.
  - apply_patch attempted to replace a file by deleting and re-adding it: report.csv
  Create a same-folder backup or a clearly named new output file before touching the original.

Agent: "The direct overwrite was blocked by the source-file guard.
        I'll use an in-place patch instead."

*** Update File: report.csv
@@ -3,1 +3,1 @@
-old value
+new value
```

> This is a representative example. When a real block-and-recovery log is captured, it will replace this section.

## What it blocks

| Operation | Example | Result |
|---|---|---|
| Delete + re-add same file | `*** Delete File: foo.csv` then `*** Add File: foo.csv` | Blocked |
| Move/replace via patch | `*** Move to: foo.csv` | Blocked |
| `Remove-Item`, `rm`, `del` on a user file | `Remove-Item Documents\foo.csv` | Blocked |
| `cp`, `copy`, `cpi` without backup destination | `cp foo.py bar.py` | Blocked |
| Copy where source has backup name but dest does not | `Copy-Item foo_backup.csv -Destination bar.csv` | Blocked |
| Destructive shell op with unresolvable target | `Remove-Item $target` | Blocked (fail-closed) |
| Redirect overwrite on a protected path | `... > Documents\foo.csv` | Blocked |
| Stderr redirect to file | `cmd 2> error.log` | Blocked |
| Fake backup destination in non-command JSON field | `"note": "-Destination foo_backup.csv"` with real dest `bar.csv` | Blocked |

## What it allows

| Operation | Example | Result |
|---|---|---|
| In-place edit via patch | `*** Update File: foo.csv` | Allowed |
| Backup copy with `.bak` suffix | `Copy-Item foo.csv -Destination foo.csv.bak_before_edit` | Allowed |
| `apply_patch` on exempt paths (`.codex\`, `tmp\`) | `*** Update File: .codex/config.json` | Allowed |
| Stderr merge to stdout | `cmd 2>&1 \| grep pattern` | Allowed |

## Requirements

- [OpenAI Codex CLI](https://github.com/openai/codex) and/or [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- **PowerShell version (Windows):** PowerShell 5.1 or later (built into Windows)
- **Python version (cross-platform):** Python 3.8 or later

## Installation

### Option A: PowerShell (Windows / Codex CLI)

1. Create the validators directory and copy the script:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.codex\validators"
Copy-Item validators\prevent_source_overwrite.ps1 "$env:USERPROFILE\.codex\validators\"
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
   Review and trust the hook if prompted.

### Option B: Python (macOS / Linux / Codex CLI)

> **Windows + Codex CLI:** Use Option A (PowerShell) instead. The paths below assume a Unix shell.

1. Create the validators directory and copy the script:

```bash
mkdir -p ~/.codex/validators
cp validators/prevent_source_overwrite.py ~/.codex/validators/
```

2. Merge the hook definition into `~/.codex/hooks.json`.
   If you don't have a `hooks.json` yet, copy the example directly:

```bash
mkdir -p ~/.codex
cp codex/hooks.python.example.json ~/.codex/hooks.json
```

   If you already have a `hooks.json`, add the `PreToolUse` entry manually.
   See [`codex/hooks.python.example.json`](codex/hooks.python.example.json) or use the block below:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|shell_command|functions\\.shell_command|apply_patch|Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.codex/validators/prevent_source_overwrite.py",
            "timeout": 10,
            "statusMessage": "Checking source-file overwrite guard"
          }
        ]
      }
    ]
  }
}
```

### Option C: Python (Claude Code)

1. Copy the validator script:

```bash
# macOS / Linux
mkdir -p ~/.claude/validators
cp validators/prevent_source_overwrite.py ~/.claude/validators/

# Windows (PowerShell)
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\validators"
Copy-Item validators\prevent_source_overwrite.py "$env:USERPROFILE\.claude\validators\"
```

2. Add the hook to `~/.claude/settings.json`. See [`claude-code/settings.json.example`](claude-code/settings.json.example) and copy the appropriate block for your OS.

**macOS / Linux:**

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.claude/validators/prevent_source_overwrite.py"
          }
        ]
      }
    ]
  }
}
```

**Windows:**

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "python \"$env:USERPROFILE\\.claude\\validators\\prevent_source_overwrite.py\"",
            "shell": "powershell"
          }
        ]
      }
    ]
  }
}
```

## Running tests

**PowerShell:**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File validators\prevent_source_overwrite.tests.ps1
```

**Python:**

```bash
python validators/prevent_source_overwrite_test.py
```

Expected output (both versions):

```
PASS blocks empty hook input: exit 2
PASS blocks apply_patch delete and add replacement: exit 2
PASS allows apply_patch update: exit 0
PASS blocks remove item against document: exit 2
PASS blocks remove item without inspectable target: exit 2
PASS allows same-folder backup copy: exit 0
PASS blocks copy-item overwrite without backup name: exit 2
PASS allows copy-item to backup name without force: exit 0
PASS blocks rm even when backup keyword appears in text: exit 2
PASS blocks ri alias against document: exit 2
PASS blocks cp without backup destination: exit 2
PASS allows cp to backup destination: exit 0
PASS blocks copy-item when source has backup name but destination does not: exit 2
PASS allows copy-item with -Destination backup name: exit 0
PASS allows copy-item with -Dest shorthand backup name: exit 0
PASS blocks copy when fake backup destination is in non-command field: exit 2
PASS blocks unsafe copy in tool_input.command when input has fake backup: exit 2
PASS blocks copy when fake -Destination precedes real copy command: exit 2
PASS blocks when first copy is safe but second copy is unsafe: exit 2
PASS blocks stderr redirect to file: exit 2
PASS allows stderr merge to stdout: exit 0
```

## How it works

The agent platform (Codex or Claude Code) calls this script as a PreToolUse hook before every tool execution. The hook receives the tool name and input as JSON on stdin. It:

1. Parses the JSON and flattens all string values into a single text block
2. Scans for dangerous `apply_patch` markers (`*** Delete File:`, `*** Move to:`)
3. Scans for destructive shell operations (`Remove-Item`, `rm`, `>`, PowerShell aliases `ri`/`mi`/`sc`/`ni`, etc.) — always blocked against protected targets
4. Scans for copy operations (`Copy-Item`, `cp`, `copy`, `cpi`) — extracts the destination path (via `-Destination`/`-Dest`/`-D` or last positional arg) and allows only if it contains a backup name (`.bak`, `_backup`, `_before`, `_original`)
5. Exits with code `2` to block, `0` to allow
6. When in doubt, exits `2` (fail-closed)

## Limitations

- The `matcher` field must cover all tool names the agent uses for file I/O. If a new tool name is introduced in a future version, update the hook config accordingly.
- Hook payload format is based on Codex v0.136.0 and Claude Code as of June 2025. If the JSON structure changes in a future version, the script may need updating.
- The PowerShell version is Windows only. Use the Python version for macOS and Linux.
- PowerShell aliases (`ri`, `mi`, `sc`, `ni`) are blocked conservatively. `sc` may conflict with Windows `sc.exe` (service control) but the guard errs on the side of caution.

## License

MIT
