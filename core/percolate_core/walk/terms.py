"""Tags a walk can travel by: what a few of one source's documents share.

THE TAGGER IS LAYERED (Sirsh, M-20261028-111716-14e1). A strategy turns texts
into {tag: [document index, ...]}, and `tag` runs the ones it is told to, each
under its own limits, and says which strategy made every tag:

    frequency   word runs that recur (`fit` below): no model, no outside
                vocabulary, cheap and deterministic. The walk study (REM-1144)
                fitted it on BEAM.
    entities    named entities from spaCy: people, places, organisations,
                dates (`index.entity_labels`).
    phrases     spaCy's noun phrases, stopwords trimmed: "vertical jump".

    tags = tag(texts, ("frequency", "entities"), limits)
    # {tag: {"docs": [index, ...], "by": ["frequency", ...]}}

Nothing is hard-coded about what a tag may be: no names, no lists beyond the
stopwords a run stops at. `percolate walk index` reads the strategies and
their limits from aiq.parameters (part `index`) and writes what they find as
`walk_term` edges, each term carrying the strategies that made it.

WHY THE OTHERS EXIST. The frequency fitter drops any run held by more than
max(DF_FLOOR, DF_SHARE x documents) documents, and a recurring name is just
such a run: in BEAM 1M:15, "rebecca" is in 40 messages, 20 of them evidence
for one question, and had no postings at all (REM-1204). Entities and phrases
find the names and subjects that tie a conversation together across sittings,
under limits of their own.

The frequency strategy's method, in order:
  1. Prose: fenced code blocks are dropped; text is split into sentences and
     tokens (letters, digits and . + # / - inside a token, so 'node.js',
     'gpt-4' and 'v6.1.0' stay whole).
  2. Candidates: runs of 1 to MAX_N tokens inside a sentence that contain no
     stopword (RAKE's boundary rule), keyed lowercase.
  3. Recurrence: a candidate in fewer than MIN_DF documents is dropped.
  4. Short links: a candidate in more than max(DF_FLOOR, DF_SHARE x documents)
     documents is dropped. DF_FLOOR stays the study's 20 for every caller; an
     index reads its floor from aiq.parameters index.df_floor (50 there, by
     Sirsh's direction, until a sweep). The walk applies its own, tighter cap when it
     travels. The fit drops a candidate above this cap, so an index holds no
     posting for it.
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

from typing import Any, Callable, Mapping, Sequence

MAX_N, MIN_DF, DF_FLOOR, DF_SHARE, NEST = 3, 2, 20, 0.02, 0.9
# The entity labels spaCy's English models name: people, places, organisations, dates and the like. A parameter
# (index.entity_labels), so a deployment can narrow them. DATE is here because Sirsh named dates; REM-1204's probe
# measured the rest without it.
ENTITY_LABELS = ("PERSON", "ORG", "GPE", "LOC", "FAC", "NORP", "PRODUCT", "EVENT", "WORK_OF_ART", "LANGUAGE", "DATE")
SPACY_MODEL = "en_core_web_sm"
# The characters of each text the spaCy strategies read: REM-1204's probe read the first 3,000, and spaCy refuses a
# text over its max_length (1,000,000) and is slow well before that. index.spacy_chars.
SPACY_CHARS = 3000

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


def bounded(posting: Mapping[str, list[int]], n_docs: int, min_df: int, df_floor: int, df_share: float
            ) -> dict[str, list[int]]:
    """The tags held by at least min_df documents and at most max(df_floor, df_share x n_docs)."""
    cap = max(df_floor, df_share * n_docs)
    return {t: p for t, p in posting.items() if min_df <= len(p) <= cap}


_NLP: dict[str, Any] = {}


def _nlp(model: str) -> Any:
    if model not in _NLP:
        try:
            import spacy
        except ImportError as e:
            raise RuntimeError("the entities and phrases strategies need spaCy: pip install 'percolate-core[tags]' "
                               f"and python -m spacy download {model}") from e
        _NLP[model] = spacy.load(model)
    return _NLP[model]


def _spacy_tags(texts: Sequence[str], pick: Callable[[Any], set[str]], model: str, chars: int
                ) -> dict[str, list[int]]:
    posting: dict[str, list[int]] = defaultdict(list)
    docs = _nlp(model).pipe((FENCE.sub(" ", t)[:chars] for t in texts), batch_size=64)
    for i, doc in enumerate(docs):
        for t in sorted(pick(doc)):
            posting[t].append(i)
    return posting


def _trim(words: Sequence[str]) -> str:
    """A span's words, lower-cased, with stopwords trimmed from both ends."""
    w = [x.lower() for x in words]
    while w and w[0] in STOP:
        w.pop(0)
    while w and w[-1] in STOP:
        w.pop()
    return " ".join(w)


def entities(texts: Sequence[str], *, labels: Sequence[str] = ENTITY_LABELS, model: str = SPACY_MODEL,
             chars: int = SPACY_CHARS, min_df: int = MIN_DF, df_floor: int = DF_FLOOR, df_share: float = DF_SHARE
             ) -> dict[str, list[int]]:
    """{entity: [index, ...]}: what spaCy names under `labels`, lower-cased, within the strategy's limits."""
    want = set(labels)
    pick = lambda doc: {t for e in doc.ents if e.label_ in want for t in [_trim(x.text for x in e)] if t}
    return bounded(_spacy_tags(texts, pick, model, chars), len(texts), min_df, df_floor, df_share)


def phrases(texts: Sequence[str], *, model: str = SPACY_MODEL, chars: int = SPACY_CHARS, min_df: int = MIN_DF,
            df_floor: int = DF_FLOOR, df_share: float = DF_SHARE) -> dict[str, list[int]]:
    """{noun phrase: [index, ...]}: spaCy's noun chunks with stopwords trimmed, within the strategy's limits."""
    pick = lambda doc: {t for c in doc.noun_chunks for t in [_trim(x.text for x in c)] if t}
    return bounded(_spacy_tags(texts, pick, model, chars), len(texts), min_df, df_floor, df_share)


def frequency(texts: Sequence[str], *, max_n: int = MAX_N, min_df: int = MIN_DF, df_floor: int = DF_FLOOR,
              df_share: float = DF_SHARE, nest: float = NEST) -> dict[str, list[int]]:
    return fit(list(texts), max_n=max_n, min_df=min_df, df_floor=df_floor, df_share=df_share, nest=nest)


STRATEGIES: dict[str, Callable[..., dict[str, list[int]]]] = {
    "frequency": frequency, "entities": entities, "phrases": phrases}


def strategies_from(value: Any) -> tuple[str, ...]:
    """aiq.parameters' index.strategies -> the strategy names. One name may be a string; none means frequency."""
    if not value:
        return ("frequency",)
    return (value,) if isinstance(value, str) else tuple(value)


def provenance(strategies: Sequence[str], limits: Mapping[str, Mapping[str, Any]] | None = None) -> dict[str, Any] | None:
    """The spaCy and model versions behind the entities and phrases strategies, or None when neither ran. A rebuild
    after a spaCy or model upgrade can find different entities, so the index report names what made them."""
    ran = [s for s in strategies if s in ("entities", "phrases")]
    if not ran:
        return None
    import spacy
    models = sorted({(limits or {}).get(s, {}).get("model", SPACY_MODEL) for s in ran})
    return {"spacy": spacy.__version__,
            "models": {m: (_NLP[m].meta.get("version") if m in _NLP else None) for m in models}}


def limits_from(parameters: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
    """aiq.parameters_of('index') -> each strategy's keyword limits. A row the table lacks keeps the default."""
    p = dict(parameters)
    pick = lambda **names: {k: p[v] for k, v in names.items() if v in p}
    shared = pick(min_df="min_df")
    return {
        "frequency": {**shared, **pick(max_n="max_n", df_floor="df_floor", df_share="df_share", nest="nest")},
        "entities": {**shared, **pick(labels="entity_labels", model="spacy_model", chars="spacy_chars",
                                      df_floor="entity_df_floor", df_share="entity_df_share")},
        "phrases": {**shared, **pick(model="spacy_model", chars="spacy_chars", df_floor="phrase_df_floor",
                                     df_share="phrase_df_share")},
    }


def tag(texts: Sequence[str], strategies: Sequence[str] = ("frequency",),
        limits: Mapping[str, Mapping[str, Any]] | None = None) -> dict[str, dict[str, Any]]:
    """{tag: {"docs": [index, ...], "by": [strategy, ...]}} over the strategies named, in their order.

    A tag two strategies find is one tag (it links the same documents by the same words) that names both; its
    documents are the union, in index order, and the union is held to the widest cap of the strategies that found
    it, so a tag never comes out wider than any one strategy allows (james's review)."""
    unknown = [s for s in strategies if s not in STRATEGIES]
    if unknown:
        raise ValueError(f"unknown tagging strategy {unknown}; the strategies are {sorted(STRATEGIES)}")
    out: dict[str, dict[str, Any]] = {}
    cap: dict[str, float] = {}
    for s in strategies:
        lim = dict((limits or {}).get(s, {}))
        cap[s] = max(lim.get("df_floor", DF_FLOOR), lim.get("df_share", DF_SHARE) * len(texts))
        for t, ix in STRATEGIES[s](texts, **lim).items():
            e = out.setdefault(t, {"docs": [], "by": []})
            e["docs"] = sorted(set(e["docs"]) | set(ix))
            e["by"].append(s)
    return {t: e for t, e in out.items() if len(e["docs"]) <= max(cap[s] for s in e["by"])}
