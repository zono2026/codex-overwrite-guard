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


def extract_copy_destination(haystack):
    """Extract the destination path from a copy command.
    Priority: -Destination/-Dest/-D value > last positional arg.
    Returns destination token or None (fail closed).
    """
    dest_match = re.search(r'-(Destination|Dest|D)\s+(\S+)', haystack, re.IGNORECASE)
    if dest_match:
        return dest_match.group(2)

    cmd_match = re.search(r'\b(?:Copy-Item|cpi)\b\s+(.+)', haystack, re.IGNORECASE)
    if not cmd_match:
        cmd_match = re.search(r'\b(?:cp|copy)\b\s+(.+)', haystack, re.IGNORECASE)
    if not cmd_match:
        return None

    tokens = re.findall(r'\S+', cmd_match.group(1))
    positionals = [t for t in tokens if not t.startswith('-')]
    if len(positionals) >= 2:
        return positionals[-1]

    return None


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


def main():
    raw = sys.stdin.read().strip()

    if not raw:
        sys.stderr.write("Source overwrite guard received no hook input; failing closed.\n")
        sys.stderr.write("Hooks must provide tool-call details on stdin for this guard to evaluate the operation.\n")
        sys.exit(2)

    texts = [raw]
    try:
        data = json.loads(raw)
        collect_texts(data, texts)
    except Exception:
        pass

    haystack = '\n'.join(texts)
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
        r'|(^|[^2])>{1,2}\s*[^&]',
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
        dest = extract_copy_destination(haystack)
        if dest is None or not is_backup_destination(dest):
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
