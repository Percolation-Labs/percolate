#!/usr/bin/env bash
# EVERY GATE, ONE COMMAND. This is what CI runs, so it is what you run.
#
#     dev/check.sh                  # everything, against $DB in $CONTAINER
#     dev/check.sh --tree           # only what needs no database (~5 seconds)
#     dev/check.sh --reload         # rebuild $DB from specs/ first
#     dev/check.sh --self-model     # ONLY the from-zero self-model load (minutes)
#     CONTAINER=p8-ci DB=p8ci dev/check.sh    # after dev/ci-database.sh
#
# THERE IS NO SECOND LIST. `.github/workflows/check.yml` does not restate these
# gates; it runs this file. That is the whole design, and it replaced an
# arrangement where thirteen named steps lived in two workflow files, a list of
# eleven commands lived in prose in a commit message and a postmortem, and this
# script carried a guard comparing its list against the workflow's to keep the
# two honest. The guard worked, and was the wrong shape: a mechanism for keeping
# two copies in step is what you build when you have not noticed you could have
# one copy. `challenge-the-process` §3 -- deleting a step beats automating one --
# applied to the automation itself.
#
# WHAT WAS DELETED RATHER THAN UNIFIED, because tidying a check that was not
# earning its place only makes a neater version of the same tax:
#
#   * `dev/claims-audit.py` (711 lines) and `dev/claims-audit.csv` (1,312 rows).
#     A ratchet on a coverage percentage whose denominator was 52% claims marked
#     `ill-defined` -- bolded prose naming nothing invocable, which no test can
#     cover by construction. The actionable set was 48 rows. Regenerating the
#     CSV was a chore listed as still-pending in two separate postmortems, and
#     the tool's own review called it "a ratchet whose denominator is mostly
#     prose cries wolf, and this is the largest instance of it in the
#     repository". A number nobody could act on, guarded by a chore.
#
#   * `extension/percolate/check-references.py` as a SEPARATE gate. It still
#     runs -- it is section 5 of `dev/references.sh` now -- but it is no longer
#     a second thing to remember. Two gates one word apart, asking different
#     questions, cost 68167c1 a round trip.
#
# VERIFYING IT ON THE PLATFORM CI USES, which is not the one you are on. "CI
# runs what you run" is true of the COMMANDS and says nothing about the
# environment, and that gap shipped a red build: `mktemp -t p8check` is valid
# BSD and fails on GNU coreutils, so every gate here failed in eleven
# milliseconds on the runner having run nothing, after passing on a Mac. Before
# changing shell in this file or anything it calls:
#
#     docker run --rm -v "$PWD":/w -w /w python:3.12 bash -c '
#       git config --global --add safe.directory /w
#       pip install -q pyyaml && dev/check.sh --tree'
#
# Thirty seconds, and it is the only local check that would have caught it.
#
# `python:3.12` RATHER THAN `-slim`, and the difference is a step that could
# fail silently. The slim image has no git, so this one-liner used to open with
# `apt-get update -qq && apt-get install -y -qq git`, both quiet -- and when the
# update failed the install was skipped by the `&&`, git was absent, and
# `references.sh` failed with `git: command not found` inside a run whose whole
# purpose was to tell you whether the gates pass on Linux. A verification that
# cannot distinguish "the gate failed" from "the verification could not run" is
# the defect this repository keeps finding, arriving inside the remedy for the
# last one. The full image ships git, so there is no step to fail.
#
# THE RULE FOR ADDING ONE: a gate belongs here if it can name the specific thing
# that is wrong. A gate that reports a percentage, or that needs an exceptions
# list to stay green, is one that will be skimmed and then bypassed.
set -uo pipefail
cd "$(dirname "$0")/.."

CONTAINER="${CONTAINER:-p8-dev-db}"
DB="${DB:-p8dev}"
# EXPORTED, because --reload shells out to dev/reload.sh, which reads CONTAINER
# from the environment and defaults it to the DEV instance. Unexported, a run
# aimed at another instance (CONTAINER=p8-test-db DB=p8test ./check.sh --reload)
# would rebuild dev's database and then grade test's -- two instances, one
# command, and the wrong one modified.
export CONTAINER DB
# EXPORTED, for the same reason CONTAINER and DB are, and it was not. Several
# gates in the lists below are other scripts in this directory rather than
# python calls this file makes, and an unexported PY reached none of them: a run
# with PY set got the interpreter it asked for in `$PY dev/vocab-audit.py` and
# plain `python3` inside dev/upgrade-converges.sh, which is how a machine whose
# `python3` cannot import yaml failed one gate out of a suite that had been
# given a working interpreter. Setting a variable and not exporting it is the
# same bug as hard-coding it, one step further from the eye.
# THE INTERPRETER IS CHOSEN, NOT ASSUMED, and the choosing lives in one file.
#
# It used to be `${PY:-python3}` here, in reload.sh and in ci-database.sh --
# three answers to one question, and on this machine two of them were wrong.
# `dev/lib/python.sh` has the reasoning and the requirements; this is its
# first caller.
. "$PWD/dev/lib/python.sh"
PY="$(percolate_python)" || exit 2

# IS THE COMPILED HALF BEHIND? db_deferrals_gone() below asks it, and so does
# dev/tests/run.sh in three places. One home, because the version comparison
# this replaces was copied four times and each copy was blind the same way --
# dev/lib/parser-currency.sh has the incident and the call sites.
. "$PWD/dev/lib/parser-currency.sh"
export PY
TREE_ONLY=0; RELOAD=0; SELF_MODEL=0
for a in "$@"; do
    case "$a" in
        --tree)   TREE_ONLY=1 ;;
        --reload) RELOAD=1 ;;
        --self-model) SELF_MODEL=1 ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $a (try --tree, --reload, --self-model)" >&2; exit 2 ;;
    esac
done

# Each gate is named for the QUESTION it asks rather than the script that asks
# it, so a failure here and a failure in Actions are recognisably the same
# failure, and so two scripts with similar names stop looking like one.
# THIS IS PERCOLATE'S COPY, and it differs from p8-subsystems' dev/check.sh in
# this list alone. p8-subsystems is where this extension was built, and its
# copy also gates the board, meta, the applications, the self-model and its
# house voice, none of which this repository holds. Those gates are left out
# here, not weakened: every gate that asks a question of the extension, its
# SQL, its parser or its tree is the same line it was there, and DB_GATES
# below is unchanged. Two extension gates still run only in p8-subsystems
# until the move is finished, because they read files that stay there: "a
# table the extension ships says somewhere why it exists" (the design specs)
# and "the schema is the size it says it is" (specs/budget.toml).
TREE_GATES=(
  "The generated SQL matches the specs it came from::$PY extension/percolate/build-sql.py --check"
  "The parser's upgrade scripts match its recorded SQL surface::$PY extension/percolate_parser/write-upgrades.py --check"
  "A released version number is not reused::./dev/check-version.sh"
  "No closed vocabulary disagrees with its own copies::$PY dev/vocab-audit.py --check"
  "The semantic exceptions the database raises are core's, word for word::$PY dev/semantic-exceptions.py --check"
  "No assertion passes because its subject is missing::$PY dev/assertion-audit.py --check"
  "The superuser install step is written in one file::tree_one_superuser_step"
  "No gate lives only in CI::tree_no_gate_lives_only_in_ci"
  "No cache key is a prefix of another::tree_cache_keys_cannot_prefix"
  "Every file that should be text is text::tree_text_is_text"
  "No screenshot is committed::tree_no_screenshots"
  "dev/reload.sh drops only the database it was told to::tree_reload_honours_db"
  "An extension bump moves every versioned reference, or changes nothing::$PY .github/scripts/test_bump_extension_version.py"
)

# RELOAD DROPS ONLY THE DATABASE IT WAS TOLD TO (REM-989). Run against a stub
# `docker` that records every call and a no-op interpreter, so it needs no
# container and writes nothing. It asserts on the DROP the script sends, not on
# its exit code: past the drop the stub answers nothing and the script fails,
# which is fine here.
tree_reload_honours_db() {
    local d v
    d=$(mktemp -d)
    cat > "$d/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SHIM_LOG"
case "$*" in *default_version*) printf '%s\n' "$SHIM_VERSION" ;; esac
exit 0
SHIM
    chmod +x "$d/docker"
    v=$(sed -n "s/^default_version = '\(.*\)'/\1/p" extension/percolate/percolate.control)
    for how in env arg; do
        : > "$d/log"
        if [ "$how" = env ]; then
            env SHIM_LOG="$d/log" SHIM_VERSION="$v" PATH="$d:$PATH" PY=true CONTAINER=shim DB=p8w \
                ./dev/reload.sh >/dev/null 2>&1 || true
        else
            env SHIM_LOG="$d/log" SHIM_VERSION="$v" PATH="$d:$PATH" PY=true CONTAINER=shim \
                ./dev/reload.sh p8w >/dev/null 2>&1 || true
        fi
        if ! grep -q 'drop database if exists p8w (force)' "$d/log" \
           || grep -q 'drop database if exists p8dev' "$d/log"; then
            echo "FAILED: dev/reload.sh with p8w given by $how dropped:"
            grep -o 'drop database if exists [^ ]*' "$d/log" || echo "  nothing"
            rm -rf "$d"; return 1
        fi
    done
    rm -rf "$d"
    echo "ok    DB=p8w and \`reload.sh p8w\` each drop p8w, and never p8dev"
}

# NO NUL IN A FILE THAT IS SUPPOSED TO BE TEXT, and it is here because the class
# cost two CI round trips in one hour.
#
#   * `dev/tests/content/02-ingestion.sql` acquired one where a comment meant to
#     write the six-character JSON escape for a NUL. The self-model's loader
#     read the file (it is text), emitted the byte into its JSON payload as that
#     escape, and died at `jsonb_populate_recordset` with "unsupported Unicode
#     escape sequence" naming no file. Postgres text cannot hold a NUL.
#   * the commit fixing THAT put two more into `applications/…/ingest.py`, in
#     the sentence describing the first. Same mechanism, one file over.
#
# AND NEITHER FAILED ON A MAC. Python 3.9 -- `python3` on macOS -- compiles a
# source file containing a NUL without complaint; 3.12, which CI runs, refuses
# it: `SyntaxError: source code cannot contain null bytes`. So the local run was
# green and the runner was red, which is the shape this file's header is already
# about. This gate is five seconds and fails on any interpreter.
#
# AN ALLOWLIST OF BINARY EXTENSIONS, NOT A LIST OF TEXT ONES, and the direction
# matters: a new binary type fails here until somebody says so, where a new TEXT
# type would silently stop being checked. `git grep -I` cannot do this job -- it
# decides "binary" by looking for a NUL in the first 8000 bytes, which is the
# same sampling flaw, and it classified both offenders the wrong way for it.
tree_text_is_text() {
    $PY - <<'PY'
import subprocess, sys
BINARY = (".png", ".pdf", ".gz")
NL = b"\n"
names = subprocess.run(["git", "ls-files", "-z"], capture_output=True,
                       check=True).stdout.split(b"\0")
bad, n = [], 0
for name in names:
    if not name:
        continue
    path = name.decode()
    if path.endswith(BINARY):
        continue
    n += 1
    try:
        data = open(path, "rb").read()
    except OSError:
        continue
    i = data.find(b"\x00")
    if i >= 0:
        bad.append(f"  {path}:{data[:i].count(NL) + 1}  (byte {i})")
if bad:
    print("FAILED: a NUL byte in a file that is supposed to be text:")
    print("\n".join(bad))
    print("A Postgres text value cannot hold one, Python 3.12 will not compile")
    print("a source file containing one, and it is invisible in every editor.")
    print("It is almost always a comment that meant to write the escape.")
    sys.exit(1)
print(f"no NUL byte in any of {n} tracked files outside {', '.join(BINARY)}")
PY
}

# NO SCREENSHOT IS COMMITTED (Sirsh, 2026-09-14). Browser QA, tours and render
# scripts write captures next to their results, and git keeps every one for
# every clone. An allowlist again, for the reason tree_text_is_text gives: an
# image is refused unless it sits in an `assets/` folder a page or render reads.
tree_no_screenshots() {
    $PY - <<'PY'
import subprocess, sys
IMAGES = (".png", ".jpg", ".jpeg", ".webp", ".gif")
names = subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True).stdout.decode().split("\0")
images = [n for n in names if n.lower().endswith(IMAGES)]
bad = [n for n in images if "assets" not in n.split("/")[:-1]]
if bad:
    print("FAILED: an image outside an assets/ folder, which is where screenshots end up:")
    print("\n".join(f"  {n}" for n in bad))
    print("Keep screenshots outside git. A page's own image belongs in an assets/ folder.")
    sys.exit(1)
print(f"all {len(images)} tracked images are in assets/ folders")
PY
}

# NO GATE LIVES ONLY IN CI, which is this file's own opening claim turned into
# something that can refuse a violation of it rather than a sentence somebody
# reads.
#
# "THERE IS NO SECOND LIST" was true when it was written and stopped being
# true: `check.yml` grew a step called "The halves agree, so nothing may still
# be deferred" -- a real gate, asking pg_extension a question, in the file whose
# whole design is that it asks no questions of its own. `grep -c defer
# dev/check.sh` was 0. So the promise "run this file and you have run what CI
# runs" was false, and nothing said so; the comment asserting it was three
# hundred lines above the counterexample.
#
# THE RULE IS NARROW ON PURPOSE. A workflow step legitimately checks things
# out, installs python, builds an image and runs `dev/ci-database.sh`. What it
# may not do is ASK THE DATABASE something, because that is what a gate is here
# -- every one of them ends in psql. So: a `run:` step in check.yml that
# mentions psql is a gate, and gates live in the arrays above.
#
# `docker logs` DIAGNOSTICS ARE FINE and deliberately not matched: they print
# what failed rather than deciding whether it did.
#
# WHAT IT CANNOT SEE, said here rather than left to be discovered, because a
# check read as complete is worse than one whose edge is written down. It finds
# a CI-only gate that talks to the database THROUGH psql, which is what all of
# them do today. A step that asked the same question through a python script,
# or through `docker exec` running something else, would be a gate this cannot
# see. Not chased, because no such step exists and a check that walks every way
# a shell might reach Postgres is a check nobody can read -- but the next person
# to add one should know this will not stop them.
#
# The alternative considered and rejected was diffing the step NAMES in
# check.yml against the gate names in these arrays. It sounds tighter and is
# looser: it would have passed the moment somebody named a workflow step after
# a gate that does something else, and it fails on every legitimate setup step
# unless an allowlist is maintained -- an exceptions list, which this file's own
# rule for adding a gate says is the shape that gets skimmed and then bypassed.
tree_no_gate_lives_only_in_ci() {
    local wf=.github/workflows/check.yml hits status=0
    [ -f "$wf" ] || { echo "FAILED: $wf is missing"; return 1; }
    # Every line of a `run:` block that names psql. Line-based rather than a
    # YAML parse because the tree half has no interpreter guarantee, and a
    # `run:` block is the only place a shell command can appear in this file.
    hits=$(grep -n 'psql' "$wf") || status=$?
    case "$status" in
        1) echo "no gate in $wf -- it runs dev/check.sh and nothing asks the database itself"
           return 0 ;;
        0) printf '%s\n' "$hits" | sed 's/^/  /'
           echo "FAILED: the lines above ask the database something from inside $wf."
           echo "That is a gate, and a gate there runs nowhere else -- this file's header"
           echo "promises that running it runs what CI runs. Move it into TREE_GATES or"
           echo "DB_GATES and let the workflow keep calling dev/check.sh."
           return 1 ;;
        *) echo "FAILED: could not read $wf (grep exit $status)"; return 1 ;;
    esac
}

# NO CACHE KEY IS A PROPER PREFIX OF ANOTHER, and the two workflows that build
# one toolchain build it the same way.
#
# WHY THIS IS A GATE AND NOT A COMMENT (REM-142). `actions/cache` restores on an
# exact key match and, failing that, on ANY `restore-keys` prefix -- but the
# PRIMARY KEY IS ITSELF A RESTORE PREFIX. So `check.yml`'s toolchain key, which
# stopped where `parser-tests.yml`'s continued:
#
#     check.yml        pgrx-builder-image-<hash>              (ended here)
#     parser-tests.yml pgrx-builder-image-<hash>-<digest>
#
# took a loose hit on the other workflow's entry on every single run --
# `Cache hit for restore-key: pgrx-builder-image-4f5f0998...-c2f9db76...`, ~775 MB
# -- while `check.yml:107` carried a comment asserting that omitting
# `restore-keys` prevented exactly this. It prevents only ADDITIONAL prefixes.
#
# The comment was careful, cited the other workflow, reasoned about the failure
# mode, and was wrong about what the configuration does; nothing about it
# invited a check. That is why the replacement is a gate: the claim "these keys
# cannot collide" is now arithmetic somebody runs, not prose somebody believes.
#
# AND THE OTHER HALF, which is the cost of the fix rather than of the defect.
# The two keys are now IDENTICAL, deliberately -- both workflows build the same
# image by the same command, so one entry serves both and neither rebuilds what
# the other has. That is sound only while the two builds stay the same build, so
# the same gate compares the build commands. A sharing arrangement that depends
# on two files agreeing is a copy, and this file's own rule for a copy is that
# something has to notice when it drifts.
#
# Line-based rather than a YAML parse for tree_no_gate_lives_only_in_ci's
# reason: the tree half has no interpreter guarantee.
tree_cache_keys_cannot_prefix() {
    local wfdir=.github/workflows status=0 keys n bad=""
    [ -d "$wfdir" ] || { echo "FAILED: $wfdir is missing"; return 1; }

    # Every `key:` value in every workflow, with the file and line it came from.
    # `restore-keys:` is deliberately NOT collected -- a restore key is MEANT to
    # be a prefix, and parser-package- is one on purpose because cargo re-decides
    # what to rebuild from a near miss.
    keys=$(grep -rn '^ *key: ' "$wfdir" | sed 's/^\([^:]*\):\([0-9]*\): *key: */\1:\2 /') || true
    if [ -z "$keys" ]; then
        echo "no cache key in $wfdir -- nothing to collide"
        return 0
    fi
    n=$(printf '%s\n' "$keys" | wc -l | tr -d ' ')

    # O(n^2) over a handful of lines, and readable, which is the right trade at
    # this size. A PROPER prefix only: two identical keys are an exact match,
    # which is the intended path and is asserted to be intentional below.
    bad=$(printf '%s\n' "$keys" | awk '
        { where[NR] = $1; $1 = ""; sub(/^ /, ""); val[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++)
              for (j = 1; j <= NR; j++) {
                if (i == j) continue
                if (length(val[i]) >= length(val[j])) continue
                if (substr(val[j], 1, length(val[i])) != val[i]) continue
                printf "  %s\n    key: %s\n  is a prefix of\n  %s\n    key: %s\n",
                       where[i], val[i], where[j], val[j]
              }
        }')
    if [ -n "$bad" ]; then
        printf '%s\n' "$bad"
        echo "FAILED: the shorter key above will take a restore-key hit on the longer"
        echo "one's entry, because a primary key is itself a restore prefix. The"
        echo "restoring job then sees cache-hit: false -- set only on an EXACT match --"
        echo "so it restores the other cache, ignores it, and rebuilds. Give the"
        echo "shorter key a trailing segment of its own so the two differ mid-string"
        echo "rather than one extending the other (REM-142)."
        return 1
    fi

    # THE SHARING IS INTENTIONAL, AND HAS TO STAY TRUE. check.yml and
    # parser-tests.yml carry the same toolchain key on purpose; that is only
    # sound while they build the same image.
    local a=.github/workflows/check.yml b=.github/workflows/parser-tests.yml
    if [ -f "$a" ] && [ -f "$b" ]; then
        local ka kb ba bb
        ka=$(grep -o 'key: pgrx-builder-image.*' "$a" || true)
        kb=$(grep -o 'key: pgrx-builder-image.*' "$b" || true)
        if [ -n "$ka" ] && [ -n "$kb" ] && [ "$ka" != "$kb" ]; then
            echo "  $a  $ka"
            echo "  $b  $kb"
            echo "FAILED: these two build one toolchain image and no longer agree on its"
            echo "cache key. Either make them identical -- so one build serves both --"
            echo "or give each a key that is not a prefix of the other and say in both"
            echo "files why they are separate (REM-142)."
            return 1
        fi
        # WHAT GETS BUILT, and deliberately not how it is stored. The two may
        # differ in disk hygiene -- they did until REM-235 gave parser-tests.yml
        # check.yml's reclaim and REM-140's `rm -f`, after it ran out of disk --
        # and none of that changes a byte of the image. What must agree is the image:
        # the build command, the build args, and the tag.
        #
        # COMMENTS ARE STRIPPED FIRST, and that is not tidiness. The first
        # version of this gate took a sed range ending at /docker save/ and
        # stopped inside REM-140's comment block, on the words "and then
        # `docker save` writes a second tarball" -- so it compared a fragment
        # against a whole step and reported two identical builds as divergent.
        # An extraction whose scope is wrong is this repository's most expensive
        # recurring defect and it cost ten minutes here, inside the gate written
        # to catch a comment that was wrong about its own configuration.
        build_lines() {
            sed 's/[[:space:]]*#.*$//' "$1" \
              | grep -oE 'docker build -f [^ ]*|--build-arg [A-Z_]+=[^ ]*|-t pgrx-builder' \
              | tr -s ' '
        }
        ba=$(build_lines "$a")
        bb=$(build_lines "$b")
        if [ -n "$ka" ] && [ "$ka" = "$kb" ] && [ "$ba" != "$bb" ]; then
            echo "  $a:"; printf '%s\n' "$ba" | sed 's/^/    /'
            echo "  $b:"; printf '%s\n' "$bb" | sed 's/^/    /'
            echo "FAILED: these two share one cache key and no longer run the same build,"
            echo "so one will serve the other an image it did not make. Keep the builds"
            echo "identical, or stop sharing the key (REM-142)."
            return 1
        fi
    fi
    # AND THE TOOLCHAIN KEY CARRIES THE BASE IT IS BUILT ON, wherever it lives.
    #
    # THIS IS THE HOLE THE FIRST VERSION OF THIS GATE LEFT, found by testing it
    # against the fix that was NOT taken. Renaming check.yml's key to
    # `check-pgrx-builder-image-<hash>` removes the prefix collision and passes
    # both checks above -- and is a regression: the collision was the only thing
    # keeping a stale toolchain from being LOADED, because `cache-hit: false`
    # skipped the load. Namespace it and the hits become exact, the load starts
    # happening, and a base image that has moved under an unchanged Dockerfile
    # and Cargo.toml is served as if it were current.
    #
    # So the rule is not about the name. The toolchain image is a function of
    # its base, therefore its key must be a function of its base. `cargo pgrx
    # package` builds the .so against that base and the ABI is a function of it
    # -- the same argument dev/build-image.sh makes -- which is why
    # parser-tests.yml resolves the digest at build time rather than trusting
    # the tag.
    local k f missing=""
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        case "$k" in
            *pgrx-builder-image*) ;;
            *) continue ;;
        esac
        case "$k" in
            *steps.base.outputs.digest*) ;;
            *) missing="$missing$k
" ;;
        esac
    done <<EOF
$(grep -rn '^ *key: ' "$wfdir" | sed 's/^\([^:]*\):\([0-9]*\): *key: */\1:\2 /')
EOF
    if [ -n "$missing" ]; then
        printf '%s' "$missing" | sed 's/^/  /'
        echo "FAILED: a pgrx toolchain cache key above does not include the resolved"
        echo "base-image digest. The image is a function of its base, so the key must"
        echo "be too: without it, a base that has moved under an unchanged Dockerfile"
        echo "and Cargo.toml is an exact cache hit, and the toolchain is loaded as if"
        echo "it were current. Resolve it the way parser-tests.yml does -- read the"
        echo "FROM line, inspect the index digest -- and put it in the key (REM-142)."
        return 1
    fi

    echo "$n cache key(s), none a prefix of another; one toolchain, one build, keyed on its base"
    return $status
}

# THE SUPERUSER STEP HAS ONE HOME, dev/image-init/00-superuser.sql, and this
# keeps the copies from coming back. It was hand-written in ten places -- the
# image hook, dev/init, reload, ci-database, currency, backup, three upgrade
# gates, the rehearsal, the self-model loader -- and a fix to one kept missing
# the others: the set_config revoke (cff8674) had to be added to each by hand,
# and #24 put `grant authenticated to api_viewer` above `create role
# authenticated` in two, which stopped the image's first start. The two
# statements matched are the ones only that step makes; anything under these
# directories that needs them runs the file (docker cp, psql -f).
#
# `git grep` exits 1 for no match and 128 when it cannot search at all -- in a
# checkout git does not trust, say -- so the three are told apart rather than
# folded into "no copies found". And the one file has to say both statements
# itself, or a rename would leave this passing over a step nobody runs.
tree_one_superuser_step() {
    local one=dev/image-init/00-superuser.sql
    local pat='revoke execute on function pg_catalog\.set_config|create extension (if not exists )?percolate_parser'
    local hits status=0
    [ "$(grep -ciE "$pat" "$one" 2>/dev/null)" = 2 ] || {
        echo "FAILED: $one is missing, or no longer makes the set_config revoke and the parser install"
        return 1; }
    hits=$(git grep --untracked -n -i -E "$pat" \
        -- dev applications k8s scenarios ":!$one") || status=$?
    case "$status" in
        0) printf '%s\n' "$hits"
           echo "FAILED: the superuser step is spelled outside $one."
           echo "Run that file instead: docker cp it into the container, then psql -f."
           return 1 ;;
        1) echo "the superuser step is spelled once, in $one" ;;
        *) echo "FAILED: git grep could not search the tree (exit $status)"; return 1 ;;
    esac
}

db_gates() {
  local psql="docker exec $CONTAINER psql -U p8 -d $DB"
  DB_GATES=(
    "Every promised capability exists::db_surface"
    "Every key and every NULL means what it says::db_identity"
    "The published contract is current::$PY dev/contract-export.py --check --psql '$psql'"
    "No closed vocabulary disagrees with the live catalog::$PY dev/vocab-audit.py --check --psql '$psql'"
    "Every guarantee the specs make still holds::db_suite"
    "Nothing deferred on a database where the halves agree::db_deferrals_gone"
    "A journey somebody could complete last month still completes::db_evals"
    "The worked examples still do what the cookbook says they do::db_examples"
    "...and the contract is still current once the suite has written::$PY dev/contract-export.py --check --psql '$psql'"
    "A backup of this database would contain its data::./dev/backup-carries-the-data.sh"
    # THE OTHER HALF OF THAT ROUND TRIP. The line above proves a dump would
    # CONTAIN the rows; this proves they go back IN. Nothing checked the second
    # half, and it was false: pg_dump sets an empty search_path, so triggers
    # firing during COPY could not resolve pgcrypto's digest(), and five
    # statements failed on a live 0.2.0. A gate that tests one direction of a
    # round trip is the class 2026-09-11-fixed-at-the-copy-that-failed.md keeps
    # naming; this is the same defect in a gate rather than in a function.
    "...and those rows can be loaded back in::./dev/restore-is-possible.sh"
    "An existing database with data can reach this version::./dev/upgrade-with-data.sh"
    "A database at every released version can reach this one::./dev/upgrade-from-every-release.sh"
    "An installed parser moves to this version in place, as a fresh install would have it::./dev/parser-upgrade.sh"
    "Concurrent identical writes to one research work make one revision::./dev/research-concurrent-writes.sh"
    "A replayed upgrade converges on a fresh install::./dev/upgrade-converges.sh"
    # THE NEXT RELEASE'S FIRST HOP, which no gate above can take: they all start
    # from a tag below default_version, so the body is never replayed onto the
    # schema it describes until somebody bumps -- and the first bump past 0.2.0
    # failed on it (content.resolve_file). See dev/upgrade-converges.sh.
    "The upgrade body replays onto this version itself::FROM=self ./dev/upgrade-converges.sh"
  )
}

# THE SELF-MODEL, FROM ZERO -- behind a flag, and the flag is the honest answer
# to where this belongs rather than a way of hiding it.
#
# `applications/percolate-self-model/load.sh --from-zero` had been broken since
# `492e007` and nothing noticed for a month, because every load anybody runs is
# incremental against a database that already holds the rows. Eight defects sat
# in it by the time somebody ran it: three relations written and registered
# nowhere, three definitions ordered behind their first caller, a channel its
# own writer could not see, and a guard that read NULL as "passed" (REM-74). All
# eight are invisible to an incremental load BY CONSTRUCTION -- the thing that
# is missing is the thing the previous run left behind.
#
# NOT IN DB_GATES, and the number is why. Measured on the runner, which is the
# figure that decides this: 5m47s for the `self-model` job of check.yml, against
# 2m03s for the whole `database` job and 16s for `tree` (run 34668494624,
# 2026-09-12). Locally it is longer and the machine decides how much -- 8m40s
# on an idle Mac, 15m30s on the same Mac at load average 11 -- so quote the
# runner. Roughly two thirds of it is the load and the rest `tests.sql`, whose
# own slowest piece is one `attention_vs_recency` scan; `dev/ci-database.sh` in
# front is eight seconds.
#
# Six minutes is not a lot and it is still three times the entire database job,
# whose workflow says in as many words not to add work to it without measuring.
# It also needs a database of its own. So it is a job of its own in check.yml,
# invoked as this file with this flag -- which keeps the rule the whole script
# exists for: CI runs what you run, and there is no second list.
#
# ITS OWN DATABASE inside $CONTAINER, because --from-zero DROPS $DB. Pointing it
# at the CI database would delete the one the other gates are grading.
#
# AND NOT IN THE SAME QUARTER HOUR AS `dev/check.sh` IN THE SAME CONTAINER, if
# you want to believe workflow/03. That test counts the pg_cron tick's failures
# over the last 15 minutes, and on a busy developer machine anything heavy in
# the container starves the tick of a worker slot -- measured here at load
# average 11: 15 `job startup timeout` rows spanning exactly the minutes this
# gate ran, every tick outside them fine, and four more in the minutes the
# workflow suite was re-run afterwards. The red is about the machine, not about
# the tick and not about this gate. CI never sees it, because the `self-model`
# job runs the load and the `database` job runs the suite -- two runners, two
# containers, neither waiting on the other.
self_model_from_zero() {
    CONTAINER="$CONTAINER" DB="${SM_DB:-p8selfmodel}" \
        ./applications/percolate-self-model/load.sh --from-zero --no-export
}

# THE DEFERRALS MUST BE GONE ONCE THE HALVES AGREE, and this ran in CI and
# nowhere else. `dev/tests/run.sh` defers a compiled assertion only while
# pg_extension says `percolate` and `percolate_parser` disagree; against a
# database where the parser artefact landed they agree, so a run that still
# reports a deferral is a run that passed WITHOUT the assertions the parser job
# exists to produce. Green-because-it-looked-nowhere, in the one place designed
# to hide it.
#
# It was a named step in `check.yml` -- the only gate that was -- under a file
# whose header says "THERE IS NO SECOND LIST". `grep -c defer dev/check.sh` was
# 0 and `grep -n extversion dev/check.sh` was empty, so running every gate the
# way this file promises still did not run this one, on any machine. Found by
# `p8-subsystems-b0` while measuring the same class REM-56 is about.
#
# A DB GATE, necessarily: it asks pg_extension, so it needs the database and it
# needs the artefact installed, which is `dev/ci-database.sh` locally and the
# `parser` job's artifact in CI.
#
# NOT A FAILURE WHEN THE HALVES DISAGREE, which is the opposite polarity to the
# workflow step it replaces and is the half that makes it runnable here. A
# developer's database legitimately runs the published .so against a newer
# schema -- PACKAGING calls that window "where main is red on purpose" -- and a
# gate that failed on it would fail on every machine every day between a parser
# change and the next image. What it refuses is the combination that cannot be
# honest: the halves AGREE and something still deferred.
db_deferrals_gone() {
    local psql="docker exec $CONTAINER psql -U p8 -d $DB -tAc"
    local pv sv
    pv=$($psql "select extversion from pg_catalog.pg_extension where extname='percolate_parser'")
    sv=$($psql "select extversion from pg_catalog.pg_extension where extname='percolate'")
    if [ -z "$pv" ]; then
        echo "percolate_parser is not installed on $DB -- nothing compiled to defer"
        return 0
    fi
    if [ "$pv" != "$sv" ]; then
        echo "percolate $sv, percolate_parser $pv -- they disagree, so a deferral is honest"
        return 0
    fi
    # THE SECOND WAY TO BE BEHIND, and the reason this gate went red on its own
    # first correct run (REM-139). Agreeing versions are not a current
    # artifact: one unreleased 0.2.0 is compiled from many commits, and a .so
    # older than the crate it was built from makes a deferral correct for a
    # reason `pg_extension` cannot state. Asked here through the same one home
    # run.sh uses, so the two gates cannot disagree about what "behind" means.
    if parser_artifact_behind_source; then
        echo "percolate and percolate_parser are both $sv, and the .so"
        echo "($(parser_iso_utc "$PARSER_SO_AT")) is older than the newest commit in"
        echo "extension/percolate_parser/ ($(parser_iso_utc "$PARSER_SRC_AT")) --"
        echo "so a deferral is correct here and the version cannot say so."
        return 0
    fi
    if [ ! -s "$SUITE_OUT" ]; then
        echo "FAILED: the halves agree and the suite left no output to read."
        echo "This gate reads what db_suite already printed; if that gate did not run,"
        echo "this one cannot answer and must not pass."
        return 1
    fi
    if grep -qE '^[0-9]+ assertion\(s\)/file\(s\) deferred' "$SUITE_OUT"; then
        grep -E 'deferred' "$SUITE_OUT" | sed 's/^/  /'
        echo "FAILED: percolate and percolate_parser are both $sv -- they agree -- and the"
        echo "suite still deferred. The artefact did not land, and that run reported green"
        echo "on assertions it never made."
        return 1
    fi
    echo "percolate and percolate_parser are both $sv and nothing deferred"
}

db_identity() {
    docker cp specs/identity/checks.sql "$CONTAINER:/tmp/identity.sql" >/dev/null
    docker exec "$CONTAINER" psql -U p8 -d "$DB" -v ON_ERROR_STOP=1 -f /tmp/identity.sql
}
db_surface() {
    docker cp surface.sql "$CONTAINER:/tmp/surface.sql" >/dev/null
    docker exec "$CONTAINER" psql -U p8 -d "$DB" -v ON_ERROR_STOP=1 -f /tmp/surface.sql
}
# REQUIRE_ALL only where the database HAS pg_cron, which is the difference
# between a scratch database and the one dev/ci-database.sh builds. run.sh skips
# a file whose `-- requires:` extension is absent and NAMES the skip; a skip is
# a guarantee nobody checked, so it is printed rather than swallowed.
db_suite() {
    local req=""
    docker exec "$CONTAINER" psql -U p8 -d "$DB" -tAc \
        "select 1 from pg_extension where extname='pg_cron'" 2>/dev/null | grep -q 1 && req=1
    # TEED, so the gate below can ask what this run deferred without running
    # the suite a second time. The suite is the expensive half of the database
    # job -- running it twice to read one line of its own output would cost more
    # than the gate is worth, which is the sort of thing check.yml's header asks
    # to be measured rather than assumed.
    CONTAINER="$CONTAINER" DB="$DB" REQUIRE_ALL="$req" ./dev/tests/run.sh 2>&1 \
        | tee "$SUITE_OUT"
    return "${PIPESTATUS[0]}"
}
# THE JOURNEY SUITE, AND IT IS A GATE FOR A REASON THE OTHER GATES CANNOT COVER.
# `db_suite` above tests a MECHANISM against its spec; this tests whether a
# journey somebody could complete can still be completed, and a mechanism can be
# correct at every step of a journey that is broken end to end
# (dev/tests/evals/README.md § "Why this is not ../run.sh").
#
# It was referenced by no workflow and by no line of this file, and it had
# stopped working in four separate ways before a single scenario ran -- defaults
# naming a container that no longer existed, a fixture that could not load, two
# whole categories refused by the permission model, and sixteen assertions about
# a schema that had moved (REM-75). Nothing went red for any of it, because
# nothing was asking. That is the entire argument for this line.
#
# `--fixture` EVERY TIME, not once by hand. The fixture is persistent state and
# a gate that depends on somebody having loaded it is a gate that reports the
# last person's setup. Reloading is idempotent by requirement -- it is one of the
# things the suite asserts about itself -- so the cost is a second and the
# benefit is that a red line here is about this tree.
db_evals() {
    CONTAINER="$CONTAINER" DB="$DB" "$PY" ./dev/tests/evals/run.py --fixture
}

# THE WORKED EXAMPLES, and they were run by nothing at all.
#
# dev/examples/run.sh's own header says the cookbook pages are written from its
# transcript rather than from what a query ought to return -- which makes it the
# source of a published document and the one thing in this tree that nothing
# checked. It had been broken since identity/spec.md §4 made the shared tier a
# row: three literal nulls into NOT NULL columns, two org ids never registered
# in rbac.orgs, and no rbac.org_members row anywhere.
#
# The last of those is why this gate is worth having rather than a one-off fix.
# It did not raise. rbac.current_org_ids() intersects the token's `orgs` with
# membership, so a claim carrying `orgs` and no `sub` resolves to NO orgs -- and
# 04-tenancy, whose whole subject is that two tenants get different answers,
# printed the identical single shared row under both claims and exited 0. A
# demonstration that quietly demonstrates the opposite of its claim is the
# failure a transcript-sourced document has, and only running it finds one.
#
# Output goes nowhere: the exit code is the assertion. Read the transcript by
# running dev/examples/run.sh by hand, which is what writing a page does.
db_examples() {
    CONTAINER="$CONTAINER" DB="$DB" ./dev/examples/run.sh >/dev/null
}

PASS=(); FAIL=(); SKIP=()
# `mktemp -t <prefix>` IS BSD. On GNU coreutils -t takes a TEMPLATE and requires
# six X's -- `mktemp: too few X's in template 'p8check'`, exit 1. So $LOG was
# empty on Linux, every `>"$LOG"` failed, and all twelve gates reported FAILED
# in eleven milliseconds having run nothing at all. Green on macOS, red on every
# CI runner, and the whole selling point of this file is that CI runs what you
# run -- which is true of the COMMANDS and was never true of the PLATFORM.
LOG=$(mktemp "${TMPDIR:-/tmp}/p8check.XXXXXX")
# db_suite tees into this so db_deferrals_gone can read what it deferred
# without paying for the suite twice. Its own file rather than $LOG, because
# $LOG is truncated per gate.
SUITE_OUT=$(mktemp "${TMPDIR:-/tmp}/p8suite.XXXXXX")
trap 'rm -f "$LOG" "$SUITE_OUT"' EXIT

# THE EXIT CODE, NEVER THE LAST LINE, NEVER THROUGH A PIPE. Reading `| tail`'s
# status instead of the command's is written down in challenge-the-process §6
# and has still bitten this repository four times, once while this file was
# being written.
run_gate() {
    local what=${1%%::*} cmd=${1#*::}
    printf '  %-66.66s ' "$what"
    if eval "$cmd" >"$LOG" 2>&1; then
        echo "ok"; PASS+=("$what")
        # A PASS THAT SKIPPED SOMETHING STILL HAS TO SAY SO. Output is swallowed
        # on success, which is right for 25 lines of NOTICEs and wrong for the
        # one line that says a file did not run: `run.sh` skips a file whose
        # `-- requires:` extension is absent, and a skip is a guarantee nobody
        # checked. Verifying that `03-cron-tick.sql` had actually run took a
        # separate re-run of the suite, because this printed nothing -- which is
        # the same defect, in the reporting layer, as a check that cannot fail.
        grep -iE '^\s*[0-9]+-.*skipped|[0-9]+ file\(s\) skipped' "$LOG" \
            | sed 's/^/        /' || true
    else
        echo "FAILED ($?)"; FAIL+=("$what")
        # THE FAILING PART, NOT THE TAIL. `tail -25` is right for a gate that
        # prints one error and stops, and wrong for the suite, which prints a
        # line per file and keeps going -- so a failure in `rbac` scrolled off
        # behind forty passing lines from `agentic`, and a red CI run said only
        # "FAILED -- a guarantee the specs make is no longer held" with no name
        # attached. Second unreadable red in two hours; the first was a gate
        # that printed the single word STALE.
        #
        # So: every line that looks like a failure, with context, and then the
        # tail regardless -- because a gate that dies without printing a marker
        # (a syntax error, a missing binary) has its evidence at the end.
        if grep -qiE 'FAILED|ERROR:|INCOMPLETE|exception|Traceback' "$LOG"; then
            grep -inE -B2 -A6 'FAILED|ERROR:|INCOMPLETE|exception|Traceback' "$LOG" \
                | head -60 | sed 's/^/      /'
            echo "      ---- last lines ----"
        fi
        sed 's/^/      /' "$LOG" | tail -12
        echo ""
    fi
}

# ON ITS OWN, and only when asked. `--self-model` is not "everything plus one
# more": the gate needs a container built by dev/ci-database.sh and it needs
# minutes, so the workflow gives it a job of its own and this file gives it a
# run of its own. Asking for it alongside the rest would mean a red tree gate
# could not be seen for sixteen minutes.
if [ "$SELF_MODEL" -eq 1 ]; then
    if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
        echo "==> the self-model: SKIPPED -- no container named $CONTAINER"
        echo "    dev/ci-database.sh builds one."
        exit 2
    fi
    echo "==> the self-model, from zero (in $CONTAINER)"
    run_gate "The self-model rebuilds from the repository alone::self_model_from_zero"
    echo ""
    echo "==> ${#PASS[@]} passed, ${#FAIL[@]} failed"
    if [ "${#FAIL[@]}" -gt 0 ]; then
        for f in "${FAIL[@]}"; do echo "    FAILED:  $f"; done; exit 1
    fi
    exit 0
fi

# THE HOOK RUNS FOR NOBODY UNTIL SOMEBODY ARMS IT, and what arming costs has
# changed twice in one afternoon, so this says what is true now rather than
# what was true when it was written.
#
# `dev/githooks/pre-push` runs this file before a push, and `git config --get
# core.hooksPath` returned nothing in all three clones on this machine, so it
# had never run once for anyone. Git will not let a repository arm itself; the
# only thing that can close that gap is telling the person who is already here.
#
# ARMED ONCE, AND THE ARMING IS WHAT MEASURED IT. Three objections came out of
# that, and two of them are now fixed:
#
#   * it could not pass at all -- `python3` here is uv-managed, PEP 668 marks
#     it externally managed, and it had no PyYAML, so the first gate errored
#     and the push was refused. FIXED: `dev/lib/python.sh` now finds an
#     interpreter that can import yaml (REM-92, #82), and `dev/check.sh --tree`
#     passes with nothing set.
#   * running this file from a hook exported GIT_DIR, and a test that builds a
#     throwaway repo honoured it over its own cwd and COMMITTED to the branch
#     being pushed. FIXED in 0e8f32b -- a hook may refuse a push, it may not
#     write to the checkout to do it.
#   * and the one that stands: the hook runs `--reload`, which rebuilds
#     `p8reload` from specs/. This file's header and the hook's both say two
#     sessions doing that at once tear each other's database out. Four sessions
#     shared this checkout that afternoon, and `.git/config` is shared by every
#     worktree of a clone -- so arming it in one session arms it for all of
#     them.
#
# So: one clone, one session -- arm it, and the two fixes above are why that is
# now a good trade. A checkout several agent sessions share -- do not, until
# each has a scratch database of its own (`DB=p8mine git push`, which the hook
# already honours). Not printed in CI, where a hook is meaningless.
if [ -z "${CI:-}" ] && [ -z "$(git config --get core.hooksPath 2>/dev/null)" ]; then
    echo "note: this clone runs no git hooks, so these gates do not run before a push."
    echo "      git config core.hooksPath dev/githooks    # arms it for EVERY worktree"
    echo "      of this clone, and each push then reloads \$DB. Set DB=p8mine if you"
    echo "      share this checkout with another session."
    echo ""
fi

echo "==> the tree"
for g in "${TREE_GATES[@]}"; do run_gate "$g"; done

if [ "$TREE_ONLY" -eq 1 ]; then
    db_gates
    SKIP+=("the ${#DB_GATES[@]} database gates (--tree)")
elif ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo ""
    echo "==> the database: SKIPPED -- no container named $CONTAINER"
    echo "    dev/ci-database.sh builds the one CI uses; (cd dev && docker compose up -d)"
    echo "    starts the dev stack. These gates were not asked:"
    db_gates; for g in "${DB_GATES[@]}"; do echo "      - ${g%%::*}"; done
    SKIP+=("the ${#DB_GATES[@]} database gates (no container named $CONTAINER)")
else
    if [ "$RELOAD" -eq 1 ]; then
        echo ""; echo "==> rebuilding $DB from specs/"
        run_gate "reload $DB from this tree::./dev/reload.sh $DB"
    fi
    echo ""
    echo "==> the database ($DB in $CONTAINER)"
    db_gates
    for g in "${DB_GATES[@]}"; do run_gate "$g"; done
fi

echo ""
echo "==> ${#PASS[@]} passed, ${#FAIL[@]} failed, ${#SKIP[@]} skipped"
for s in "${SKIP[@]:-}"; do [ -n "$s" ] && echo "    skipped: $s"; done
if [ "${#FAIL[@]}" -gt 0 ]; then
    for f in "${FAIL[@]}"; do echo "    FAILED:  $f"; done
    # THE QUESTION A RED RUN DOES NOT ASK ITSELF. A database that has fallen
    # behind the tree fails these while the tree is perfectly good, and nothing
    # in the failure says so. Named here because a postmortem called it the
    # single highest-value fix left on the table and said it was one line.
    case " ${FAIL[*]} " in
      *guarantee*|*contract*|*vocabulary*|*capability*)
        echo ""
        echo "    Before reading these as defects in the tree: is the database CURRENT?"
        echo "    Existence is not currency -- a function whose body has fallen behind"
        echo "    its spec passes a clean surface audit and answers with the old answer."
        echo "        TARGET_DB=$DB dev/currency.sh      # what has drifted"
        echo "        dev/check.sh --reload              # rebuild it and check again" ;;
    esac
    exit 1
fi
# WHAT THE GREEN RUN STOOD DOWN, and it prints HERE because this is the last
# screen and a green run is exactly when nobody reads further.
#
# `dev/tests/run.sh` already computes both counts and the condition that would
# make each one run. `db_suite` tees it into $SUITE_OUT, and until now the only
# reader on the success path was `db_deferrals_gone`, which asks a narrower
# question -- so `27 passed, 0 failed` printed over three deferred files and
# said nothing about them. Measured on the session that built the deferral
# mechanism: it read that silence as "no deferrals" against a database whose
# .so was demonstrably stale, and had it for a minute as a false negative in
# its own work.
#
# A deferred assertion is a guarantee nobody checked. A red run makes somebody
# read the log; a green one does not, which is why the count has to survive to
# the end of it.
#
# ZERO PRINTS NOTHING, deliberately. A line that appears on every run is
# furniture and stops being read, and the whole value here is that its presence
# means something. `db_deferrals_gone` is untouched and still refuses a
# deferral that cannot be honest -- this reports, it does not judge.
if [ -s "${SUITE_OUT:-}" ]; then
    deferred_line=$(grep -E '^[0-9]+ assertion\(s\)/file\(s\) deferred' "$SUITE_OUT" || true)
    core_line=$(grep -E '^[0-9]+ assertion\(s\) deferred to a newer percolate-core' "$SUITE_OUT" || true)
    if [ -n "$deferred_line$core_line" ]; then
        echo ""
        echo "    STOOD DOWN, and green says nothing about it unless it is printed here:"
        # The two axes stay apart, as run.sh keeps them: one is bounded by
        # pg_extension, the other by the percolate-core pin, and a parser that
        # has caught up says nothing about a core deferral.
        [ -n "$deferred_line" ] && printf '      %s\n' "$deferred_line"
        [ -n "$core_line" ]     && printf '      %s\n' "$core_line"
        # THE CONDITION LINES, BY POSITION RATHER THAN BY PREFIX. run.sh prints
        # them indented directly under each summary, and the first version of
        # this matched three prefixes it had read off one example -- against a
        # real run the line is "both halves are 0.1.6, and the .so (...) is",
        # a fourth, and nothing printed. A check that walks only the cases
        # somebody configured has a hole shaped like the thing it is for, which
        # is the ledger entry this file already carries a gate for.
        grep -A2 -E '^[0-9]+ assertion\(s\)' "$SUITE_OUT" \
            | grep -E '^  ' | sed 's/^  /      /' || true
    fi
fi
# THE LAST LINE SAYS WHAT DID NOT RUN. It printed "every gate CI runs is green
# on this machine" whatever had happened: after `--tree`, and after a run that
# found no container and skipped all fourteen database gates, a few lines below
# the list naming them as skipped. A green run is the one nobody scrolls back
# through, so the last line is the one that has to be true.
#
# And even a full run is not every gate CI runs: the `self-model` job is
# `dev/check.sh --self-model`, which this invocation does not include.
if [ "${#SKIP[@]}" -gt 0 ]; then
    echo "    green, and NOT every gate CI runs -- skipped: $(printf '%s; ' "${SKIP[@]}" | sed 's/; $//')."
else
    echo "    every gate in CI's tree and database jobs is green on this machine (the self-model job is --self-model)."
fi
