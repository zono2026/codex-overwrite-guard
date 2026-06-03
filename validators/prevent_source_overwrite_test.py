#!/usr/bin/env python3
import subprocess
import sys
import json
import os

script = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'prevent_source_overwrite.py')

tests = [
    {
        'name': 'blocks empty hook input',
        'payload': None,
        'expected': 2,
    },
    {
        'name': 'blocks apply_patch delete and add replacement',
        'payload': {
            'tool': 'apply_patch',
            'input': '*** Delete File: Documents/foo.csv\n*** Add File: Documents/foo.csv'
        },
        'expected': 2,
    },
    {
        'name': 'allows apply_patch update',
        'payload': {
            'tool': 'apply_patch',
            'input': '*** Update File: Documents/foo.csv\n@@\n-old\n+new'
        },
        'expected': 0,
    },
    {
        'name': 'blocks remove item against document',
        'payload': {
            'tool': 'Bash',
            'command': r'Remove-Item -LiteralPath C:\Users\testuser\Documents\foo.csv'
        },
        'expected': 2,
    },
    {
        'name': 'blocks remove item without inspectable target',
        'payload': {
            'tool': 'Bash',
            'command': 'Remove-Item $target'
        },
        'expected': 2,
    },
    {
        'name': 'allows same-folder backup copy',
        'payload': {
            'tool': 'Bash',
            'command': r'Copy-Item -LiteralPath C:\Users\testuser\Documents\foo.csv -Destination C:\Users\testuser\Documents\foo.csv.bak_before_edit -Force'
        },
        'expected': 0,
    },
    {
        'name': 'blocks copy-item overwrite without backup name',
        'payload': {
            'tool': 'Bash',
            'command': r'Copy-Item -LiteralPath C:\Users\testuser\Documents\foo.csv -Destination C:\Users\testuser\Documents\bar.csv'
        },
        'expected': 2,
    },
    {
        'name': 'allows copy-item to backup name without force',
        'payload': {
            'tool': 'Bash',
            'command': r'Copy-Item -LiteralPath C:\Users\testuser\Documents\foo.csv -Destination C:\Users\testuser\Documents\foo_backup.csv'
        },
        'expected': 0,
    },
    {
        'name': 'blocks rm even when backup keyword appears in text',
        'payload': {
            'tool': 'Bash',
            'command': r"echo 'creating backup' ; rm C:\Users\testuser\Documents\foo.csv"
        },
        'expected': 2,
    },
    {
        'name': 'blocks ri alias against document',
        'payload': {
            'tool': 'Bash',
            'command': r'ri C:\Users\testuser\Documents\foo.csv'
        },
        'expected': 2,
    },
    {
        'name': 'blocks cp without backup destination',
        'payload': {
            'tool': 'Bash',
            'command': r'cp C:\Users\testuser\Documents\new.py C:\Users\testuser\Documents\foo.py'
        },
        'expected': 2,
    },
    {
        'name': 'allows cp to backup destination',
        'payload': {
            'tool': 'Bash',
            'command': r'cp C:\Users\testuser\Documents\foo.py C:\Users\testuser\Documents\foo_backup.py'
        },
        'expected': 0,
    },
    {
        'name': 'blocks copy-item when source has backup name but destination does not',
        'payload': {
            'tool': 'Bash',
            'command': r'Copy-Item C:\Users\testuser\Documents\foo_backup.csv -Destination C:\Users\testuser\Documents\bar.csv'
        },
        'expected': 2,
    },
    {
        'name': 'allows copy-item with -Destination backup name',
        'payload': {
            'tool': 'Bash',
            'command': r'Copy-Item -LiteralPath C:\Users\testuser\Documents\foo.csv -Destination C:\Users\testuser\Documents\foo_backup.csv'
        },
        'expected': 0,
    },
    {
        'name': 'allows copy-item with -Dest shorthand backup name',
        'payload': {
            'tool': 'Bash',
            'command': r'Copy-Item -LiteralPath C:\Users\testuser\Documents\foo.csv -Dest C:\Users\testuser\Documents\foo_backup.csv'
        },
        'expected': 0,
    },
    {
        'name': 'blocks copy when fake backup destination is in non-command field',
        'payload': {
            'tool': 'Bash',
            'note': r'pretend -Destination C:\Users\testuser\Documents\foo_backup.csv',
            'command': r'Copy-Item -LiteralPath C:\Users\testuser\Documents\foo.csv -Destination C:\Users\testuser\Documents\bar.csv'
        },
        'expected': 2,
    },
    {
        'name': 'blocks stderr redirect to file',
        'payload': {
            'tool': 'Bash',
            'command': r'somecmd 2> C:\Users\testuser\Documents\error.log'
        },
        'expected': 2,
    },
    {
        'name': 'allows stderr merge to stdout',
        'payload': {
            'tool': 'Bash',
            'command': 'somecmd 2>&1 | grep pattern'
        },
        'expected': 0,
    },
]

failed = False
for test in tests:
    input_data = '' if test['payload'] is None else json.dumps(test['payload'])
    result = subprocess.run(
        [sys.executable, script],
        input=input_data,
        capture_output=True,
        text=True
    )
    actual = result.returncode
    if actual != test['expected']:
        failed = True
        print(f"FAIL {test['name']}: expected {test['expected']}, got {actual}")
    else:
        print(f"PASS {test['name']}: exit {actual}")

sys.exit(1 if failed else 0)
