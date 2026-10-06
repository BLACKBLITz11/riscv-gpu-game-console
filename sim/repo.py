"""Finds files anywhere in the repository, so the scripts do not care which folder a file is in."""
import os
import sys

SIM_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SIM_DIR)               # the repository folder
_SKIP = {'__pycache__', 'simwork', 'cpusimwork', 'docs'}
_cache = {}


def find(name):
    """Full path of the file called `name` somewhere inside the repository."""
    if not _cache:
        for folder, dirs, files in os.walk(ROOT):
            dirs[:] = [d for d in dirs if d not in _SKIP and not d.startswith('.')]
            for f in files:
                _cache.setdefault(f, os.path.join(folder, f))
    if name not in _cache:
        raise SystemExit(f"missing file: {name} (looked in {ROOT})")
    return _cache[name]


# let `import assembler` and `import rvasm` work wherever those two files live
for _tool in ('assembler.py', 'rvasm.py'):
    try:
        sys.path.insert(0, os.path.dirname(find(_tool)))
    except SystemExit:
        pass