#!/usr/bin/env python3
"""Copy only an authorized DeepSeek key; never print or track secret values."""
import json
import os
from pathlib import Path
import re
import secrets

home = Path.home()
root = home / '.local/share/tencentdb-memory/secrets'
key = os.environ.get('DEEPSEEK_API_KEY', '').strip()
if not key:
    source = Path(os.environ.get('DSH_HOME', str(home / '.config/dsh'))) / '.credentials.yaml'
    # Deliberately limited parser for DSH's refs scalar. Never evaluate YAML/shell.
    text = source.read_text()
    refs = re.search(r'(?ms)^refs:\s*\n(.*?)(?=^\S|\Z)', text)
    match = re.search(r'^  DEEPSEEK_API_KEY: (.+)$', refs[1], re.M) if refs else None
    if not match:
        raise SystemExit('No DEEPSEEK_API_KEY scalar in DSH refs; set it in the environment.')
    value = match[1].strip()
    if value.startswith('"'):
        key = json.loads(value)
    elif value.startswith("'") and value.endswith("'"):
        key = value[1:-1].replace("''", "'")
    else:
        key = value
if not isinstance(key, str) or not re.fullmatch(r'sk-[A-Za-z0-9_-]+', key):
    raise SystemExit('Unsupported key/reference format; refusing to write credentials.')

root.mkdir(parents=True, exist_ok=True, mode=0o700)
if root.is_symlink():
    raise SystemExit('Secret directory must not be a symlink.')
root.chmod(0o700)

def save_new(name, value):
    path = root / name
    if path.is_symlink():
        raise SystemExit('Refusing a symlink secret target.')
    if path.exists():
        if name == 'deepseek-api-key' and path.read_text().strip() != value:
            raise SystemExit('Existing DeepSeek copy differs; rotate it explicitly, then recreate the container.')
        path.chmod(0o600)
        return
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(value + '\n')

save_new('deepseek-api-key', key)
save_new('gateway-api-key', secrets.token_urlsafe(32))
print('Service-specific secret files ready (0600); values not displayed.')
