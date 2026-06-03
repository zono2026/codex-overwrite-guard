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
