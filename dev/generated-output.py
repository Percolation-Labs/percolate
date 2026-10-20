#!/usr/bin/env python3
"""Refuse a tracked file that a script in this repository writes.

    dev/generated-output.py                    # list every one in the tree
    dev/generated-output.py --check            # refuse what THIS BRANCH adds
    dev/generated-output.py --check --base X   # against another ref

WHY THIS EXISTS. On 2026-09-20 one session committed 38,447 lines under a
research application's directory in the tree this one was cut from, of which
34,372 were JSON that the scripts beside them wrote. They were committed so numbers could be
cited in a README, which a README does by writing the number down. Nothing
judged the size at any point, because size is not the defect -- being
regenerable is, and that is a property a gate can read.

WHY AST AND NOT A REGEX. The question is "does a script write this path", which
is a fact about the code rather than about how it is spelled. A regex over
`write_text` would miss `json.dump(x, open(p, 'w'))` and would fire on the word
in a comment. The parser answers it exactly, and this repository's rule is to
make it exact or drop it.

WHAT IT READS. Three ways a script in this tree names a file it writes:
  (HERE / 'x.json').write_text(...)        and .open('w') / .write_bytes(...)
  open(HERE / 'x.json', 'w')               and pathlib's open with a mode
  add_argument('--out', default=HERE / 'x.json')

`HERE` is any expression; only the literal on the right of the last `/` is
taken, and it is resolved against the script's own directory, which is what
`HERE = Path(__file__).resolve().parent` means everywhere in this tree.

WHAT `--check` GRADES, and the reasoning is the house-voice gate's. It reads the
files this branch ADDS, not the whole tree. There are thirteen already here --
a built site, published pages, frozen label sets, demo data -- and most were
somebody's deliberate call. Refusing them all would make this a gate people pass
`--no-verify` around, and a gate everybody bypasses protects nothing. The bare
command lists all thirteen for anybody who wants to argue one.

WHAT IT DOES NOT CATCH, said plainly so nobody trusts it too far: a path built
from a variable, a loop over names, or an output directory passed in at the
command line. It is a floor, not a proof.
"""
import argparse
import os
import ast
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
WRITERS = {'write_text', 'write_bytes'}
OUT_FLAGS = {'--out', '--output', '--outfile', '--out-file'}
# A file this branch adds that a script writes, kept anyway. Each entry says why,
# and the reason has to be that recreating it costs something -- money, a
# network, or a frozen commitment that would change if it were regenerated --
# never that it is convenient.
ALLOWED: dict[str, str] = {
    # Empty at the move from the private tree (REM-1080), whose entries were all
    # research files that are not here.
}


def literal_name(node):
    """The filename at the end of `<anything> / 'x.json'`, or None."""
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
        right = node.right
        if isinstance(right, ast.Constant) and isinstance(right.value, str):
            return right.value
    if isinstance(node, ast.Constant) and isinstance(node.value, str) and '/' not in node.value:
        return node.value
    return None


def written_by(source):
    """Every filename this module writes, as far as the parser can tell."""
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return set()
    found = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        if isinstance(func, ast.Attribute):
            if func.attr in WRITERS:
                name = literal_name(func.value)
                if name:
                    found.add(name)
            # p.open('w') on a Path
            if func.attr == 'open' and node.args:
                mode = node.args[0]
                if isinstance(mode, ast.Constant) and isinstance(mode.value, str) \
                        and set('wxa') & set(mode.value):
                    name = literal_name(func.value)
                    if name:
                        found.add(name)
            if func.attr == 'add_argument':
                flags = [a.value for a in node.args
                         if isinstance(a, ast.Constant) and isinstance(a.value, str)]
                if set(flags) & OUT_FLAGS:
                    for keyword in node.keywords:
                        if keyword.arg == 'default':
                            name = literal_name(keyword.value)
                            if name:
                                found.add(name)
        elif isinstance(func, ast.Name) and func.id == 'open' and len(node.args) > 1:
            mode = node.args[1]
            if isinstance(mode, ast.Constant) and isinstance(mode.value, str) \
                    and set('wxa') & set(mode.value):
                name = literal_name(node.args[0])
                if name:
                    found.add(name)
    return found


def tracked():
    out = subprocess.run(['git', '-C', str(ROOT), 'ls-files', '-z'],
                         capture_output=True, check=True).stdout.decode()
    return set(out.split('\0')) - {''}


def added(base):
    """Paths this branch adds against `base`, or None for the whole tree."""
    if base is None:
        return None
    merge_base = subprocess.run(['git', '-C', str(ROOT), 'merge-base', base, 'HEAD'],
                                capture_output=True, text=True)
    if merge_base.returncode:
        return None
    out = subprocess.run(['git', '-C', str(ROOT), 'diff', '--diff-filter=A', '--name-only', '-z',
                          merge_base.stdout.strip(), 'HEAD'],
                         capture_output=True, check=True).stdout.decode()
    return set(out.split('\0')) - {''}


def offences(base=None):
    files = tracked()
    new = added(base)
    rows = []
    for name in sorted(files):
        if not name.endswith('.py'):
            continue
        path = ROOT / name
        if not path.exists():
            continue
        for written in sorted(written_by(path.read_text(errors='replace'))):
            target = str((Path(name).parent / written).as_posix())
            if target not in files or target in ALLOWED:
                continue
            if new is not None and target not in new:
                continue
            rows.append((target, name))
    return rows


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--check', action='store_true',
                   help='exit 1 on a regenerable file this branch adds')
    p.add_argument('--base', default=os.environ.get('CHANGED_BASE') or 'origin/main',
                   help='what --check compares against ($CHANGED_BASE, else origin/main)')
    args = p.parse_args()
    rows = offences(args.base if args.check else None)
    if not rows:
        print('nothing this branch adds is written by a script here' if args.check
              else f'no tracked file is written by a script here ({len(tracked())} tracked)')
        return 0
    print('FAILED: this branch adds files that a script in this repository writes:'
          if args.check else 'tracked files that a script here writes:')
    for target, writer in rows:
        print(f'  {target}')
        print(f'      written by {writer}')
    print('\nA regenerable file does not belong in git. Delete it, and write the number')
    print('it was committed for into the prose that cites it. If it must stay -- because')
    print('recreating it costs money or needs a network -- add it to ALLOWED in')
    print('dev/generated-output.py with the reason.')
    return 1 if args.check else 0


if __name__ == '__main__':
    sys.exit(main())
