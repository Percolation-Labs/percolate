#!/usr/bin/env python3
import argparse
import subprocess
import toml
import os
import sys
 
MODULE_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..' ))
PYPROJECT = os.path.join(MODULE_ROOT, 'pyproject.toml')
VERSION_FILE = os.path.join(MODULE_ROOT, '__version__')

def run(*cmd, check=True, **kwargs):
    return subprocess.run(cmd, check=check, **kwargs)

def read_poetry_version():
    data = toml.load(PYPROJECT)
    return data['tool']['poetry']['version']

def bump_semver(version, major=False, minor=False):
    x, y, z = map(int, version.split('.'))
    if major:
        x += 1
        y = 0
        z = 0
    elif minor:
        y += 1
        z = 0
    else:
        z += 1
    return f"{x}.{y}.{z}"

def write_version_file(version):
    with open(VERSION_FILE, 'w') as f:
        f.write(version)

def main():
    p = argparse.ArgumentParser(description="Bump semver, update Poetry, write __version__, and tag")
    grp = p.add_mutually_exclusive_group()
    grp.add_argument('--minor', action='store_true', help="bump minor (X.Y+1.0)")
    grp.add_argument('--major', action='store_true', help="bump major (X+1.0.0)")
    p.add_argument('--no-tag', dest='tag', action='store_false', help="don't create/push git tag")
    p.set_defaults(tag=True)
    args = p.parse_args()

    old = read_poetry_version()
    new = bump_semver(old, major=args.major, minor=args.minor)
    print(f"Bumping version: {old} → {new}")

    os.chdir(MODULE_ROOT)
    run('poetry', 'version', new)

    write_version_file(new)
    run('git', 'add', 'pyproject.toml', '__version__')
    run('git', 'commit', '-m', f'Bump version to {new}')

    if args.tag:
        tag_name = f"v{new}"
        run('git', 'tag', tag_name)
        run('git', 'push', 'origin', tag_name)

    # Always push the branch changes
    run('git', 'push', '--no-tags', 'origin', 'HEAD')

if __name__ == '__main__':
    main()