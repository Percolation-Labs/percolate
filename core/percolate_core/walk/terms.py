"""Terms a walk can travel by: word runs that a few of one source's documents share.

No model and no outside vocabulary. The walk study (REM-1144) fitted this on
BEAM and kept it because it is cheap, deterministic and reads only the
tenant's own text; `percolate walk index` runs it once per source and writes
what it finds as `walk_term` edges.

    terms = fit(texts)            # {term: [document index, ...]}, in a stable order

Method, in order:
  1. Prose: fenced code blocks are dropped; text is split into sentences and
     tokens (letters, digits and . + # / - inside a token, so 'node.js',
     'gpt-4' and 'v6.1.0' stay whole).
  2. Candidates: runs of 1 to MAX_N tokens inside a sentence that contain no
     stopword (RAKE's boundary rule), keyed lowercase.
  3. Recurrence: a candidate in fewer than MIN_DF documents is dropped.
  4. Short links: a candidate in more than max(DF_FLOOR, DF_SHARE x documents)
     documents is dropped. The walk applies its own, tighter cap when it
     travels; the postings above it are kept so an audit can say a term was
     too wide to offer rather than absent.
  5. Nesting (C-value's idea): a shorter candidate that occurs almost only
     inside one longer kept candidate (at least NEST of its documents) is
     dropped in favour of the longer one.

The study's tagger also had a background filter (a word common in general
English links everything) and spaCy and YAKE candidate sources. The walk's
runs used neither -- `TermTagger(max_zipf=99)` turns the background off -- so
neither is here.

THE ORDER IS SORTED, NOT HASHED. The study iterated a Python set of
candidates, so a document's term list came out in an order that changed with
PYTHONHASHSEED. The list's order is stored (a term's rank on its edge), so
here it is the order of first appearance over documents taken in order, with
each document's candidates sorted.
"""

from __future__ import annotations

import re
from collections import defaultdict

MAX_N, MIN_DF, DF_FLOOR, DF_SHARE, NEST = 3, 2, 20, 0.02, 0.9

FENCE = re.compile(r"```.*?(?:```|$)", re.S)
SENT = re.compile(r"(?<=[.!?])\s+|\n+")
TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9.+#/_-]*[A-Za-z0-9+#]|[A-Za-z0-9]")
STOP = set("""a an the and or but nor so yet for of to in on at by with from into onto over under about above below between
through during before after since until than as if then else when while where whether which who whom whose what why how
i me my mine myself we us our ours you your yours he him his she her hers it its they them their theirs this that these
those there here am is are was were be been being have has had having do does did doing will would shall should can could
may might must not no yes also just only very really quite too more most much many some any all each every both few other
such own same again further once up down out off any anything something nothing everything someone anyone everyone thing
things way ways get got make made like want need trying try tried use using used able sure well good great thanks thank
please help hi hello let lets i'm i've i'd i'll it's that's what's can't don't doesn't didn't isn't aren't wasn't won't
ok okay hmm yeah one two three first second new now still even maybe actually currently already""".split())


def candidates(text: str, max_n: int = MAX_N) -> set[str]:
    """Every stopword-free run of 1 to max_n tokens inside one sentence."""
    out: set[str] = set()
    for sent in SENT.split(FENCE.sub(" ", text)):
        run: list[str] = []
        for tok in TOKEN.findall(sent):
            t = tok.lower().rstrip(".")
            if t in STOP or (len(t) < 2 and not t.isdigit()):
                for n in range(1, max_n + 1):
                    out.update(" ".join(run[i:i + n]) for i in range(len(run) - n + 1))
                run = []
            else:
                run.append(t)
        for n in range(1, max_n + 1):
            out.update(" ".join(run[i:i + n]) for i in range(len(run) - n + 1))
    return out


def fit(texts: list[str], *, max_n: int = MAX_N, min_df: int = MIN_DF, df_floor: int = DF_FLOOR,
        df_share: float = DF_SHARE, nest: float = NEST) -> dict[str, list[int]]:
    """{term: [index of each document holding it, ascending]}, in first-appearance order."""
    posting: dict[str, list[int]] = defaultdict(list)
    for i, text in enumerate(texts):
        for c in sorted(candidates(text, max_n)):
            posting[c].append(i)
    cap = max(df_floor, df_share * len(texts))
    kept = {t: p for t, p in posting.items() if min_df <= len(p) <= cap}
    longer: dict[str, list[str]] = defaultdict(list)
    for t in kept:
        ws = t.split()
        for n in range(1, len(ws)):
            for i in range(len(ws) - n + 1):
                sub = " ".join(ws[i:i + n])
                if sub in kept:
                    longer[sub].append(t)
    for sub, sups in longer.items():
        if any(len(kept[s]) >= nest * len(kept[sub]) for s in sups):
            kept.pop(sub, None)
    return kept


def terms_of(postings: dict[str, list[int]]) -> dict[int, list[str]]:
    """{document index: its terms, in the postings' order} -- the list a term's rank is a place in."""
    out: dict[int, list[str]] = defaultdict(list)
    for t, ix in postings.items():
        for i in ix:
            out[i].append(t)
    return dict(out)
