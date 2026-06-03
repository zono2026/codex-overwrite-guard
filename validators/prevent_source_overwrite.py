#!/usr/bin/env python3
"""
prevent_source_overwrite.py
PreToolUse hook for Codex CLI and Claude Code.
Blocks AI agents from overwriting or deleting source files without an explicit backup.
Exit 2 = block, Exit 0 = allow.
"""

import sys
import json
import re


def collect_texts(value, texts):
    if value is None:
        return
    if isinstance(value, str):
        texts.append(value)
    elif isinstance(value, dict):
        for k, v in value.items():
            texts.append(str(k))
            collect_texts(v, texts)
    elif isinstance(value, list):
        for item in value:
            collect_texts(item, texts)
    else:
        texts.append(str(value))


def normalize_path(text):
    if not text or not text.strip():
        return ""
    text = text.strip().strip('"').strip("'")
    text = re.sub(r'^\\\\\?\\', '', text)
    text = text.replace('/', '\\').lower()
    return text


def is_exempt_path(text):
    path = normalize_path(text)
    if not path:
        return False
    return bool(
        re.search(r'\\.codex\\', path) or
        re.search(r'\\appdata\\local\\temp\\', path) or
        re.search(r'\\tmp\\', path) or
        re.search(r'(^|[\\._-])(bak|backup|original|before)([\\._-]|$)', path)
    )


def is_backup_destination(token):
    path = normalize_path(token)
    if not path:
        return False
    if '\\' not in path and '.' not in path:
        return False
    return bool(re.search(r'(^|[\\._-])(bak|backup|original|before)([\\._-]|$)', path))


def extract_copy_destinations(text):
    """Extract destinations from all copy commands in the text.
    Each copy command is scoped to its segment (delimited by ; | & newline).
    Returns a list of destination strings (None for unresolvable destinations).
    Empty list means no copy commands found.
    """
    if not text:
        return []

    destinations = []
    # Find all copy commands, scoped to their segment.
    # Copy-Item/cpi are tried first (via alternation order) to prevent
    # 'copy' from matching inside 'Copy-Item'.
    copy_re = re.compile(
        r'\b(?:Copy-Item|cpi)\b\s*([^;|&\n]*)'
        r'|\b(?:cp|copy)\b\s*([^;|&\n]*)',
        re.IGNORECASE
    )
    for m in copy_re.finditer(text):
        args = m.group(1) if m.group(1) is not None else m.group(2)
        # Check for -Destination/-Dest/-D within this segment
        dest_match = re.search(r'-(Destination|Dest|D)\s+(\S+)', args, re.IGNORECASE)
        if dest_match:
            destinations.append(dest_match.group(2))
            continue
        # Positional args
        tokens = re.findall(r'\S+', args)
        positionals = [t for t in tokens if not t.startswith('-')]
        if len(positionals) >= 2:
            destinations.append(positionals[-1])
        else:
            destinations.append(None)  # fail closed

    return destinations


def has_protected_target(text):
    if not text:
        return False
    normalized = normalize_path(text)
    if re.search(r'\\.codex\\', normalized):
        return False
    return bool(
        re.search(r'\\users\\[^\\]+\\(documents|desktop|downloads|onedrive)\\', normalized) or
        re.search(
            r'\.(csv|tsv|xlsx|xls|xlsm|docx|doc|pdf|txt|md|json|toml|yaml|yml|ps1|py|js|ts|tsx|jsx|html|css|sql)(\s|"|\'|$)',
            normalized
        )
    )


def extract_all_command_texts(data):
    """Extract all command-like strings from parsed JSON.
    Checks command, tool_input.command, and input (in that order).
    Returns a list of unique strings. Empty list if none found.
    """
    if not isinstance(data, dict):
        return []
    results = []
    # Direct 'command' field (Bash tool)
    if 'command' in data and isinstance(data['command'], str):
        results.append(data['command'])
    # Nested tool_input.command
    tool_input = data.get('tool_input')
    if isinstance(tool_input, dict):
        cmd = tool_input.get('command')
        if isinstance(cmd, str) and cmd not in results:
            results.append(cmd)
    # 'input' field (apply_patch, etc.) — lowest priority
    if 'input' in data and isinstance(data['input'], str):
        inp = data['input']
        if inp not in results:
            results.append(inp)
    return results


def main():
    raw = sys.stdin.read().strip()

    if not raw:
        sys.stderr.write("Source overwrite guard received no hook input; failing closed.\n")
        sys.stderr.write("Hooks must provide tool-call details on stdin for this guard to evaluate the operation.\n")
        sys.exit(2)

    texts = [raw]
    json_parsed = False
    command_texts = []
    try:
        data = json.loads(raw)
        json_parsed = True
        collect_texts(data, texts)
        command_texts = extract_all_command_texts(data)
    except Exception:
        pass

    haystack = '\n'.join(texts)
    # For copy destination extraction, use only actual command strings.
    # If JSON parsed but no command fields found, use empty string (fail closed).
    # Fall back to haystack only if JSON parse itself failed (raw text input).
    if command_texts:
        copy_sources = command_texts
    elif json_parsed:
        copy_sources = [""]
    else:
        copy_sources = [haystack]
    reasons = []

    delete_paths = set()
    for m in re.finditer(r'(?m)^\*\*\* Delete File:\s*(.+?)\s*$', haystack):
        path = m.group(1)
        if not is_exempt_path(path):
            reasons.append(f"apply_patch attempted to delete a file: {path}")
        delete_paths.add(normalize_path(path))

    for m in re.finditer(r'(?m)^\*\*\* Move to:\s*(.+?)\s*$', haystack):
        path = m.group(1)
        if not is_exempt_path(path):
            reasons.append(f"apply_patch attempted to move/replace a file: {path}")

    for m in re.finditer(r'(?m)^\*\*\* Add File:\s*(.+?)\s*$', haystack):
        add_path = normalize_path(m.group(1))
        if add_path in delete_paths and not is_exempt_path(m.group(1)):
            reasons.append(
                f"apply_patch attempted to replace a file by deleting and re-adding it: {m.group(1)}"
            )

    destructive_shell = re.search(
        r'\b(Remove-Item|Move-Item|Set-Content|Out-File|New-Item|rm|del|erase|mv|ri|mi|sc|ni)\b'
        r'|>{1,2}\s*(?!&)\S',
        haystack,
        re.IGNORECASE | re.MULTILINE
    )

    copy_shell = re.search(
        r'\b(Copy-Item|cp|copy|cpi)\b',
        haystack,
        re.IGNORECASE
    )

    if destructive_shell:
        if has_protected_target(haystack):
            reasons.append(
                "shell command contains a destructive operation targeting a protected source file."
            )
        else:
            reasons.append(
                "shell command uses destructive syntax, but the target could not be inspected; failing closed."
            )

    if copy_shell and not destructive_shell:
        all_dests = []
        for src in copy_sources:
            all_dests.extend(extract_copy_destinations(src))

        if not all_dests or any(d is None or not is_backup_destination(d) for d in all_dests):
            if has_protected_target(haystack):
                reasons.append(
                    "copy command targets a protected file without a backup-named destination."
                )
            else:
                reasons.append(
                    "copy command target could not be inspected; failing closed."
                )

    if reasons:
        sys.stderr.write("Source overwrite guard blocked this tool call.\n")
        for r in reasons:
            sys.stderr.write(f"- {r}\n")
        sys.stderr.write(
            "Create a same-folder backup or a clearly named new output file before touching the original. "
            "Modify the original only after explicit user confirmation.\n"
        )
        sys.exit(2)

    sys.exit(0)


if __name__ == '__main__':
    main()
