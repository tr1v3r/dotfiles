"""Offline regression tests; requires python3, bash, rsync and chezmoi.

Run: python3 scripts/test_dsh_migrate_desktop_home.py
Only temporary fixture homes are modified; process enumeration is mocked.
"""

import os
import pathlib
import shutil
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parent.parent
script = repo / 'scripts/dsh-migrate-desktop-home.sh'
rule = repo / 'symlink_dot_dsh.tmpl'
real_chezmoi = shutil.which('chezmoi')
assert real_chezmoi and shutil.which('rsync'), 'Install chezmoi and rsync to run these tests'
base = pathlib.Path(tempfile.gettempdir()).resolve()
root = pathlib.Path(tempfile.mkdtemp(prefix='dsh-home-test-', dir=base)).resolve()
assert root.parent == base and root.name.startswith('dsh-home-test-')
print('Fixture root:', root)


def put(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def setup(name):
    home = root / name
    src = home / '.dsh'
    dst = home / '.config/dsh'
    src.mkdir(parents=True)
    dst.mkdir(parents=True)
    bindir = home / 'bin'
    bindir.mkdir()
    put(bindir / 'ps', '#!/bin/sh\nprintf "/usr/bin/bash\\n"\n')
    (bindir / 'ps').chmod(0o755)
    source = home / 'source'
    source.mkdir()
    # Use the real template with HOME set to this fixture home.
    shutil.copyfile(rule, source / rule.name)
    put(home / 'empty.toml', '')
    wrapper = f'#!/bin/sh\nexec "{real_chezmoi}" -c "{home}/empty.toml" -S "{source}" -D "{home}" --persistent-state "{home}/state.db" --cache "{home}/cache" "$@"\n'
    put(bindir / 'chezmoi', wrapper)
    (bindir / 'chezmoi').chmod(0o755)
    env = os.environ.copy()
    for k in ('DSH_MIGRATE_SRC', 'DSH_MIGRATE_DST', 'DSH_SESSION_ID'):
        env.pop(k, None)
    env.update(HOME=str(home), PATH=str(bindir) + ':' + env['PATH'])
    return home, src, dst, env


def run(env, args=(), success=True, contains=None):
    result = subprocess.run(['/bin/bash', str(script), *args], env=env, text=True, capture_output=True)
    if (result.returncode == 0) != success:
        raise AssertionError(result.stdout + result.stderr)
    if contains:
        assert contains in result.stdout + result.stderr, result.stdout + result.stderr
    return result


try:
    h, s, d, e = setup('conflicts')
    for rel in ('.credentials.yaml', '.anonymous-user-id', 'sessions/ws/session-a/log.zstd',
                'storages/workspace.json', 'memory/ltm.db', 'profiles/desktop/package.json'):
        put(s / rel, 'old\n')
        put(d / rel, 'current\n')
    put(s / 'sessions/ws/session-b/log.zstd', 'missing\n')
    put(s / 'sessions/ws/session-b/session.lock', 'lock\n')
    put(s / 'profiles/desktop/old-plugin.js', 'do not mix\n')
    put(s / 'memory/ltm.db-wal', 'do not mix\n')
    run(e)
    for rel in ('.credentials.yaml', '.anonymous-user-id', 'sessions/ws/session-a/log.zstd',
                'storages/workspace.json', 'memory/ltm.db', 'profiles/desktop/package.json'):
        assert (d / rel).read_text() == 'current\n'
        assert (s / rel).read_text() == 'old\n'
    assert (d / 'sessions/ws/session-b/log.zstd').read_text() == 'missing\n'
    assert not (d / 'sessions/ws/session-b/session.lock').exists()
    assert not (d / 'profiles/desktop/old-plugin.js').exists()
    assert not (d / 'memory/ltm.db-wal').exists()
    print('PASS conflict preservation and missing session copy')

    h, s, d, e = setup('fresh')
    put(s / '.credentials.yaml', 'fixture\n')
    put(s / 'memory/ltm.db', 'fixture\n')
    put(s / 'profiles/desktop/package.json', '{}\n')
    put(s / 'profiles/desktop/lock', 'fixture\n')
    run(e)
    assert (d / '.credentials.yaml').read_text() == 'fixture\n'
    assert (d / 'memory/ltm.db').read_text() == 'fixture\n'
    assert (d / 'profiles/desktop/package.json').read_text() == '{}\n'
    assert not (d / 'profiles/desktop/lock').exists()
    print('PASS missing memory and whole profile copy')

    h, s, d, e = setup('preview')
    put(s / 'sessions/ws/session/log.zstd', 'fixture\n')
    run(e, ['--dry-run', '--link'])
    assert s.is_dir() and not s.is_symlink()
    assert not list(d.iterdir())
    assert not list(h.glob('.dsh.backup-*'))
    print('PASS dry run makes no home changes')

    h, s, d, e = setup('process-error')
    put(h / 'bin/ps', '#!/bin/sh\necho denied >&2\nexit 1\n')
    run(e, ['--link'], success=False, contains='cannot inspect processes')
    assert s.is_dir() and not list(d.iterdir())
    print('PASS denied process query aborts')

    h, s, d, e = setup('running')
    put(h / 'bin/ps', '#!/bin/sh\nprintf "/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness\\n"\n')
    run(e, ['--link'], success=False, contains='Desktop is running')
    assert s.is_dir() and not list(d.iterdir())
    run(e, ['--link', '--force'], success=False, contains='cannot be combined')
    print('PASS running Desktop and live link refusal')

    h, s, d, e = setup('nested')
    e['DSH_MIGRATE_DST'] = str(s / 'nested')
    run(e, ['--force'], success=False, contains='inside source')
    assert not (s / 'nested').exists()
    print('PASS nested-path refusal')

    h, s, d, e = setup('link')
    put(s / 'sessions/ws/new/log.zstd', 'old session\n')
    put(s / '.credentials.yaml', 'old fixture\n')
    put(d / '.credentials.yaml', 'new fixture\n')
    run(e, ['--link'])
    assert s.is_symlink() and s.resolve() == d.resolve()
    backups = list(h.glob('.dsh.backup-*'))
    assert len(backups) == 1
    assert (backups[0] / '.credentials.yaml').read_text() == 'old fixture\n'
    assert (d / '.credentials.yaml').read_text() == 'new fixture\n'
    assert (d / 'sessions/ws/new/log.zstd').read_text() == 'old session\n'
    run(e, ['--link'], contains='nothing to migrate')
    assert len(list(h.glob('.dsh.backup-*'))) == 1
    print('PASS real chezmoi template, backup, link apply and idempotence')

    h, s, d, e = setup('bad-rule')
    put(h / 'source/symlink_dot_dsh.tmpl', str(h / 'wrong') + '\n')
    run(e, ['--link'], success=False, contains='must target')
    assert s.is_dir() and not list(h.glob('.dsh.backup-*'))
    print('PASS invalid rule aborts before move')

    for name, rel, target in [('interrupted-memory', 'memory/ltm.db', 'memory'),
                              ('interrupted-profile', 'profiles/desktop/package.json', 'profiles/desktop')]:
        h, s, d, e = setup(name)
        put(s / rel, 'complete fixture\n')
        real_rsync = shutil.which('rsync')
        put(h / 'bin/rsync', '#!/bin/bash\nif [ "${TEST_RSYNC_FAIL:-0}" = 1 ]; then target="${@: -1}"; mkdir -p "$target"; printf partial > "$target/partial"; exit 23; fi\nexec "' + real_rsync + '" "$@"\n')
        (h / 'bin/rsync').chmod(0o755)
        e['TEST_RSYNC_FAIL'] = '1'
        run(e, success=False)
        assert not (d / target).exists()
        assert s.is_dir()
        e['TEST_RSYNC_FAIL'] = '0'
        run(e, ['--link'])
        assert s.is_symlink() and (d / rel).read_text() == 'complete fixture\n'
        assert not (d / target / 'partial').exists()
    print('PASS interrupted tree copy can be retried safely')

    h, s, d, e = setup('reverse-alias')
    # Empty fixture target is known and resolved before this directory removal.
    assert d.resolve() == h.resolve() / '.config/dsh' and not list(d.iterdir())
    d.rmdir()
    d.symlink_to(s, target_is_directory=True)
    run(e, ['--link'], success=False, contains='not the intended')
    assert not s.is_symlink()
    print('PASS reverse alias is not reported as a deployed link')

    h, s, d, e = setup('failed-apply')
    put(s / '.credentials.yaml', 'old fixture\n')
    put(h / 'bin/chezmoi', '#!/bin/sh\nif [ "$1" = cat ]; then printf "%s/.config/dsh\\n" "$HOME"; else exit 2; fi\n')
    run(e, ['--link'], success=False, contains='old home is safe')
    backups = list(h.glob('.dsh.backup-*'))
    assert len(backups) == 1 and (backups[0] / '.credentials.yaml').read_text() == 'old fixture\n'
    print('PASS failed deployment preserves complete backup')
finally:
    # This exact resolved fixture root was verified before deleting it.
    assert root.parent == base and root.name.startswith('dsh-home-test-')
    shutil.rmtree(root)
