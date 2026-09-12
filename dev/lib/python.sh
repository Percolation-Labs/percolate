# THE ONE ANSWER TO "WHICH INTERPRETER RUNS build-sql.py", sourced by every
# script that needs one: check.sh, reload.sh and ci-database.sh.
#
# There were three answers before this file, which is how a question stops
# having one: ci-database.sh pip-installed PyYAML into `$PY` and errored with
# instructions if it could not, reload.sh took a bare unexported
# `${PY:-python3}`, and check.sh took `${PY:-python3}` too. On a machine whose
# `python3` is a uv-managed 3.13 -- no PyYAML, and PEP 668 refuses to install
# into it -- the first worked and the other two produced a red about the
# machine. check.sh's first gate is "The generated SQL matches the specs it came
# from"; it went red on a tree where all ten gates were green.
#
# What that cost, on 2026-09-12: the pre-push hook could not start, two sessions
# pushed with `--no-verify`, and main took a merge whose generated SQL had not
# been regenerated -- which is precisely what that first gate asks about. A gate
# that cannot start is not a gate that was bypassed, and it is the worse of the
# two: nothing in the output says the check did not happen.
#
# TWO REQUIREMENTS, and a machine can fail either:
#
#   yaml       build-sql.py reads the spec order from YAML.
#   >= 3.12    CI's version. NOT a formality: `/usr/bin/python3` on a Mac is
#              3.9 and does have yaml, and 3.9 compiles a source file containing
#              a NUL where 3.12 refuses it -- the exact divergence
#              check.sh's `tree_text_is_text` gate exists because of. Falling
#              back to it buys a green local run and a red runner.
#
# An explicit PY is honoured without argument: somebody who names an interpreter
# is answering this question themselves, and a script that overrules them is one
# they will stop running.

# OUTSIDE THE CHECKOUT, deliberately. `meta/postmortems/2026-09-12-a-gate-that-
# can-write.md` argues the rule this has to satisfy: a pre-push hook may read
# the tree and refuse the push, and may not write to the tree, to the branch, or
# to anything shared. The hook calls check.sh, which calls this, so a venv under
# `dev/` would be a hook writing into somebody's working copy during a push --
# gitignored, and still a write. A cache directory is not the tree, is shared by
# every worktree on the machine rather than built per clone, and can be deleted
# by anybody at any time with no effect but one slow run.
PERCOLATE_PY_VENV="${PERCOLATE_PY_VENV:-${XDG_CACHE_HOME:-$HOME/.cache}/percolate/gates-venv}"

# Both requirements in one call, because asking them separately reports the
# first failure and hides the second.
percolate_py_usable() {
    "$1" -c 'import sys, yaml; sys.exit(0 if sys.version_info >= (3, 12) else 1)' >/dev/null 2>&1
}

percolate_py_new_enough() {
    "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' >/dev/null 2>&1
}

# Prints an interpreter on stdout, or explains on stderr and returns 1.
percolate_python() {
    local candidate
    if [ -n "${PY:-}" ]; then printf '%s' "$PY"; return 0; fi

    for candidate in python3 python3.13 python3.12 "$PERCOLATE_PY_VENV/bin/python"; do
        command -v "$candidate" >/dev/null 2>&1 && percolate_py_usable "$candidate" && {
            printf '%s' "$candidate"; return 0; }
    done

    # Installing into the interpreter is tried BEFORE building a venv, because
    # on a CI runner it is the cheap answer and it is what ci-database.sh did
    # here for a year. It fails on a PEP 668 install, which is why there is a
    # second step rather than only this one.
    for candidate in python3 python3.13 python3.12; do
        command -v "$candidate" >/dev/null 2>&1 && percolate_py_new_enough "$candidate" || continue
        "$candidate" -m pip install --quiet pyyaml >/dev/null 2>&1 && percolate_py_usable "$candidate" && {
            printf '%s' "$candidate"; return 0; }
    done

    for candidate in python3.13 python3.12 python3; do
        command -v "$candidate" >/dev/null 2>&1 && percolate_py_new_enough "$candidate" || continue
        echo "==> no interpreter here has PyYAML; building $PERCOLATE_PY_VENV once" >&2
        "$candidate" -m venv "$PERCOLATE_PY_VENV" >/dev/null 2>&1 \
            && "$PERCOLATE_PY_VENV/bin/python" -m pip install --quiet pyyaml >/dev/null 2>&1 \
            && percolate_py_usable "$PERCOLATE_PY_VENV/bin/python" && {
                printf '%s' "$PERCOLATE_PY_VENV/bin/python"; return 0; }
        rm -rf "$PERCOLATE_PY_VENV"
        break
    done

    # BY NAME. What is wrong is the machine, and a script that says so is one
    # somebody can fix in a minute; a failed gate is one they learn to skip.
    echo "build-sql.py needs Python >= 3.12 with PyYAML, which is what CI runs." >&2
    echo "  tried: python3 ($(python3 --version 2>&1 | tail -1)), python3.13, python3.12," >&2
    echo "         installing pyyaml into each, and a venv at $PERCOLATE_PY_VENV" >&2
    echo "  fix:   PY=/path/to/python3.12 <command>" >&2
    return 1
}
