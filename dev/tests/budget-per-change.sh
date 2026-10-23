#!/usr/bin/env bash
# The schema budget survives a merge in either order, and names what nobody declared (REM-1142).
#
#     dev/tests/budget-per-change.sh
#
# Builds a throwaway git repository with a two-file schema and runs dev/the-schema-has-a-budget.py against it:
#   1. two branches that each add one function, each declaring it in its own specs/budget.d file, merge into
#      main in either order with no conflict and no edit to a shared line, and the gate passes after each;
#   2. a branch that adds a function it did not declare is refused, by the function's name;
#   3. a branch that raises budget.toml's total by hand -- the shared counter that lost increments three times
#      in two days -- is refused;
#   4. --fold moves the declarations into the totals, and the folded tree passes.
# No database, no network: it is a tree gate, and this is its test.
set -euo pipefail

GATE="$(cd "$(dirname "$0")/../.." && pwd)/dev/the-schema-has-a-budget.py"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
gate() { python3 "$GATE" --root "$T" --base "$1"; }
g() { git -C "$T" -c user.name=test -c user.email=test@example.invalid "$@"; }

mkdir -p "$T/extension/percolate" "$T/specs/identity" "$T/specs/budget.d"
printf 'ORDER = [\n    ("a.sql", "one"),\n    ("b.sql", "two"),\n]\n' > "$T/extension/percolate/build-sql.py"
printf 'create or replace function s.fzero() returns int as $$ select 0 $$ language sql;\n' > "$T/specs/a.sql"
printf 'create or replace function s.fone() returns int as $$ select 1 $$ language sql;\n' > "$T/specs/b.sql"
: > "$T/specs/identity/closing.sql"
printf '[declared]\ntables    = 0\nviews     = 0\nfunctions = 2\n' > "$T/specs/budget.toml"
g init -q -b main && g add -A && g commit -q -m base
gate main > /dev/null || fail "the base tree does not pass"

add() {   # branch file function [declare]
    g checkout -q -b "$1" main
    printf 'create or replace function %s() returns int as $$ select 9 $$ language sql;\n' "$3" >> "$T/specs/$2"
    mkdir -p "$T/specs/budget.d"
    if [ "${4:-declare}" = declare ]; then
        printf 'why = "a test addition"\n\n[added]\nfunctions = ["%s"]\n' "$3" > "$T/specs/budget.d/$1.toml"
    fi
    g add -A && g commit -q -m "$1"
    gate main > /dev/null || fail "branch $1 alone does not pass"
    g checkout -q main
}
add one a.sql s.fa
add two b.sql s.fb

# 1. Both orders, each on its own main.
for order in "one two" "two one"; do
    set -- $order
    g checkout -q -b "main-$1-$2" main
    for b in "$@"; do
        before=$(g rev-parse HEAD)
        g merge -q --no-edit "$b" || fail "merging $b ($order) conflicted"
        out=$(gate "$before") || { echo "$out"; fail "the gate refused main after merging $b ($order)"; }
    done
    g diff --quiet main -- specs/budget.toml || fail "merging $order edited specs/budget.toml"
    [ "$(ls "$T/specs/budget.d" | wc -l | tr -d ' ')" = 2 ] || fail "both declarations should survive $order"
    g checkout -q main
done
echo "ok   two branches that each add a function merge in either order, untouched totals, gate green"

# 2. An undeclared addition is refused by name.
g checkout -q -b sneaky main
printf 'create or replace function s.fc() returns int as $$ select 3 $$ language sql;\n' >> "$T/specs/a.sql"
g add -A && g commit -q -m sneaky
if out=$(gate main); then fail "an undeclared function passed"; fi
grep -q "this branch adds s.fc and no specs/budget.d file of its own declares it" <<<"$out" \
    || { echo "$out"; fail "the refusal does not name s.fc"; }
g checkout -q main
echo "ok   an undeclared addition is refused, naming s.fc"

# 3. Raising the shared total by hand is refused, even when the count then matches.
g checkout -q -b by-hand main
printf 'create or replace function s.fd() returns int as $$ select 4 $$ language sql;\n' >> "$T/specs/a.sql"
sed -i.bak 's/^functions = 2$/functions = 3/' "$T/specs/budget.toml" && rm "$T/specs/budget.toml.bak"
g add -A && g commit -q -m by-hand
if out=$(gate main); then fail "a hand-raised total passed"; fi
grep -q "only --fold moves the totals" <<<"$out" || { echo "$out"; fail "the refusal does not say why"; }
g checkout -q main
echo "ok   a hand-raised total in specs/budget.toml is refused"

# 4. The fold, first at a tag: a release that shipped only branch one folds only one's declaration.
g checkout -q -b fold-at main-one-two
g tag shipped-one main-one-two^1   # main after merging one, before two: what that release shipped
python3 "$GATE" --root "$T" --fold --at shipped-one > /dev/null
grep -q '^functions = 3$' "$T/specs/budget.toml" || fail "--fold --at should raise functions to 3, folding only one"
[ "$(ls "$T/specs/budget.d")" = "two.toml" ] || fail "--fold --at should leave two's declaration for the next train"
g add -A && g commit -q -m fold-at
out=$(gate main-one-two) || { echo "$out"; fail "the tree folded at a tag does not pass"; }
g checkout -q main-one-two
echo "ok   --fold --at folds only what the tag shipped, leaves the rest, and passes"

# 5. The fold of everything.
before=$(g rev-parse HEAD)
python3 "$GATE" --root "$T" --fold > /dev/null
grep -q '^functions = 4$' "$T/specs/budget.toml" || fail "the fold did not raise functions to 4"
[ -z "$(ls "$T/specs/budget.d")" ] || fail "the fold left declarations behind"
g add -A && g commit -q -m fold
out=$(gate "$before") || { echo "$out"; fail "the folded tree does not pass"; }
echo "ok   --fold moves both declarations into the totals and the folded tree passes"
