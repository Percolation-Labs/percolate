"""Evaluation harness, not product: a worked example, drawn from a finished walk's own rows and set against BEAM's
reference answer (oracle-given labels).

    python3 harness/examples.py DSN RUN QID OUT_PREFIX

BEAM's question, reference answer and rubric for QID come from samples/beam/questions.jsonl, which
harness/beam_fetch.py writes from the downloaded BEAM; harness/answer-items.json is our own grouping of the evidence
exchanges into the rubric's items (by its position in BEAM's rubric) or, where BEAM's rubric has no items, into
threads we name. Everything else comes from the run: aiq.walk_reads (what it read, in order, and the lead that
brought each read in), aiq.walk_clues (each lead's source, kind, P and decision), aiq.walk_search_order (search's own
ranking for the same question), and what each exchange said from its node's summary.

Writes OUT_PREFIX-answer.txt (each rubric item, the exchange the walk read for it, when and how),
OUT_PREFIX-coverage.png (rubric items covered against reads, walk and search) and OUT_PREFIX-path.png (the compressed
traversal: every path from a search read through the leads to an evidence exchange).
"""
import json, subprocess, sys
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

dsn, run, qid, out = sys.argv[1:5]
HERE = Path(__file__).resolve().parent
beam = {q['qid']: q for q in map(json.loads, open(HERE.parent / 'samples/beam/questions.jsonl'))}[qid]
grouping = json.load(open(HERE / 'answer-items.json'))[qid]
ans = {'question': beam['question'], 'answer': beam['answer'], 'gold': beam['gold'],
       'items': [{'item': g['item'] if 'item' in g else beam['rubric'][g['rubric']], 'docs': g['docs']} for g in grouping]}

def q(sql):
    r = subprocess.run(['psql', dsn, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', sql], capture_output=True, text=True, check=True)
    return json.loads(r.stdout or 'null')

reads = q(f"select json_agg(json_build_object('doc', doc, 'wave', wave, 'ord', ord, 'via', via) order by wave, ord) "
          f"from aiq.walk_reads('{run}')")
clues = {c['key']: c for c in q(f"select json_agg(json_build_object('key', key, 'kind', kind, 'source', source, 'p', p, "
                                  f"'decision', decision)) from aiq.walk_clues('{run}')")}
srank = {r['doc']: r['rank'] for r in q(f"select json_agg(json_build_object('doc', doc, 'rank', rank)) "
                                        f"from aiq.walk_search_order('{run}')")}
# what each evidence exchange said: its node's summary, reached by its key
said = {r['doc']: r['said'] for r in q("select json_agg(json_build_object('doc', d, 'said', left(n.summary, 120))) "
                                       "from unnest(array[" + ','.join(f"'{d}'" for d in ans['gold']) + "]) d "
                                       "cross join lateral aiq.lookup(d) l join aiq.nodes n on n.id = l.node_id")}
n_of = {r['doc']: i + 1 for i, r in enumerate(reads)}        # read number, 1-based, in the walk's order
by_doc = {r['doc']: r for r in reads}
num = lambda d: int(d.split('/')[1])
labels = [i['item'] for i in ans['items']]

# 1. The answer that came back: for each rubric item, the first of its exchanges the walk read.
lines = [f"question: {ans['question']}", f"BEAM's reference answer: {ans['answer']}", ""]
first = []
for lab, it in zip(labels, ans['items']):
    got = sorted((n_of[d], d) for d in it['docs'] if d in n_of)
    best_search = min((srank.get(d, 10**6) for d in it['docs']), default=10**6)
    first.append((lab, got[0] if got else None, best_search, it['docs']))
w = max(len(l) for l in labels)
lines.append(f"{'rubric item':<{w}} | read | exchange        | how                         | search rank | evidence read")
for lab, g, sr, docs in first:
    if g:
        n, d = g
        via = by_doc[d]['via']
        how = 'search' if via == 'search' else f"{via.split(':')[0]} lead, P {clues[via]['p']:.2f}" if via in clues else via
    else:
        n, d, how = '-', '(not read)', ''
    read_k = sum(1 for x in docs if x in n_of)
    lines.append(f"{lab:<{w}} | {n!s:>4} | {d:<15} | {how:<27} | {sr if sr < 10**6 else 'past 2000':>11} | {read_k} of {len(docs)}")
lines.append("")
lines.append("in the conversation's order, the first exchange read for each item:")
for lab, g, _, _ in sorted(first, key=lambda x: num(x[1][1]) if x[1] else 10**9):
    if g:
        lines.append(f"  {lab}: {said.get(g[1], '')}")
open(out + '-answer.txt', 'w').write('\n'.join(lines) + '\n')

# 2. Coverage against reads: an item counts once any of its exchanges has been read.
SURFACE, INK, INK2, MUTED, GRID = '#fcfcfb', '#0b0b0b', '#52514e', '#8a8984', '#e6e5e0'
BLUE, ORANGE = '#2a78d6', '#eb6834'
plt.rcParams.update({'font.family': 'DejaVu Sans', 'axes.edgecolor': GRID, 'axes.labelcolor': INK2, 'xtick.color': INK2,
                     'ytick.color': INK2, 'axes.facecolor': SURFACE, 'figure.facecolor': SURFACE, 'axes.spines.top': False,
                     'axes.spines.right': False, 'axes.grid': True, 'grid.color': GRID, 'grid.linewidth': 0.8,
                     'axes.axisbelow': True})
N = len(reads)
def covered(rank_of):
    return [sum(1 for it in ans['items'] if any(rank_of.get(d, 10**6) <= k for d in it['docs'])) for k in range(1, N + 1)]
cw, cs = covered(n_of), covered(srank)
def found(rank_of):
    return [sum(1 for d in ans['gold'] if rank_of.get(d, 10**6) <= k) for k in range(1, N + 1)]
ew, es = found(n_of), found(srank)
f, axes = plt.subplots(1, 2, figsize=(12, 4.4))
for ax, (w_, s_, top, ylab) in zip(axes, [(cw, cs, len(ans['items']), f"rubric items with evidence read (of {len(ans['items'])})"),
                                       (ew, es, len(ans['gold']), f"evidence exchanges read (of {len(ans['gold'])})")]):
    ax.step(range(1, N + 1), w_, where='post', color=BLUE, lw=2, label='walk')
    ax.step(range(1, N + 1), s_, where='post', color=ORANGE, lw=2, label="search's top N")
    for k in (50, 100, 500):
        if k <= N:
            ax.annotate(f"{w_[k-1]} vs {s_[k-1]}", (k, w_[k-1]), textcoords='offset points', xytext=(4, 6), fontsize=10, color=INK)
    ax.set_xlim(0, N); ax.set_ylim(0, top + 0.5); ax.yaxis.get_major_locator().set_params(integer=True)
    ax.set_xlabel('exchanges read'); ax.set_ylabel(ylab)
def firsts(xs):
    return {c: xs.index(c) + 1 for c in sorted(set(xs)) if c}
open(out + '-coverage.txt', 'w').write(json.dumps({'items_walk': firsts(cw), 'items_search': firsts(cs),
    'evidence_walk': firsts(ew), 'evidence_search': firsts(es),
    'at': {k: {'items': [cw[k-1], cs[k-1]], 'evidence': [ew[k-1], es[k-1]]} for k in (50, 100, 500) if k <= N}}) + '\n')
axes[1].legend(frameon=False, loc='lower right', labelcolor=INK2)
f.tight_layout(); f.savefig(out + '-coverage.png', dpi=160); plt.close(f)

# 3. The compressed traversal: every path from a search read through travelled leads to an evidence exchange.
def parent(d):
    via = by_doc[d]['via']
    return None if via == 'search' or via not in clues else clues[via]['source']
keep, depth = set(), {}
def dep(d):
    if d not in depth:
        p = parent(d)
        depth[d] = 0 if p is None or p not in by_doc else dep(p) + 1
    return depth[d]
for d in ans['gold']:
    x = d
    while x in by_doc and x not in keep:
        keep.add(x); x = parent(x)
item_of = {d: i for i, it in enumerate(ans['items']) for d in it['docs']}
missed = [d for d in ans['gold'] if d not in n_of]
# One row per exchange, in the conversation's order: rows are evenly spaced, so neighbours never overlap.
row = {d: i for i, d in enumerate(sorted(keep | set(missed), key=num))}
CAT = ['#2a78d6', '#eb6834', '#1f9e74', '#8c5cc4', '#c9a227', '#d6457a', '#4a8f9e']
f, ax = plt.subplots(figsize=(11, 0.32 * len(row) + 1.6))
style = {'term': '-', 'next': (0, (4, 2)), 'near': (0, (1, 2))}
labelled = set()
for d in keep:
    p = parent(d)
    if p in keep:
        k = clues[by_doc[d]['via']]
        ax.annotate('', (dep(d), row[d]), (dep(p), row[p]),
                    arrowprops=dict(arrowstyle='-|>', color=MUTED, lw=1.2, ls=style.get(k['kind'], '-'), shrinkA=6, shrinkB=6))
        if k['kind'] == 'term' and k['key'] not in labelled:
            labelled.add(k['key'])
            ax.text(dep(p) + 0.5, row[p] + (row[d] - row[p]) / 2, f"{k['key'][5:]} {k['p']:.2f}", fontsize=7.5, color=INK2,
                    ha='center', va='center', bbox=dict(boxstyle='round,pad=0.15', fc=SURFACE, ec='none'))
for d in keep:
    ev = d in item_of
    ax.plot(dep(d), row[d], 'o', ms=9 if ev else 6, color=CAT[item_of[d] % len(CAT)] if ev else MUTED,
            markeredgecolor=SURFACE, markeredgewidth=1.5, zorder=3)
    tag = f"read {n_of[d]}" if ev else (f"search rank {srank.get(d)}" if by_doc[d]['via'] == 'search' else '')
    ax.text(dep(d) + 0.07, row[d], f"#{num(d)}  {tag}", fontsize=7.5, color=INK if ev else INK2, va='center')
for d in missed:
    ax.plot(-0.7, row[d], 'o', ms=9, mfc='none', mec=CAT[item_of[d] % len(CAT)], mew=2, zorder=3)
    ax.text(-0.63, row[d], f"#{num(d)}  not read", fontsize=7.5, color=INK2, va='center')
ax.invert_yaxis(); ax.set_yticks([]); ax.grid(axis='y', visible=False)
ax.set_xlabel('links from a search read'); ax.set_ylabel("exchanges, in the conversation's order")
ax.set_xticks(range(0, max(depth[d] for d in keep) + 1)); ax.set_xlim(-0.95 if missed else -0.3, max(depth[d] for d in keep) + 0.9)
handles = [Line2D([], [], color=MUTED, ls=style[k], label=f'{k} lead') for k in ('term', 'next', 'near')]
handles += [Line2D([], [], marker='o', ls='', color=CAT[i % len(CAT)], label=l) for i, l in enumerate(labels)]
if missed:
    handles += [Line2D([], [], marker='o', ls='', mfc='none', mec=MUTED, mew=2, label='evidence not read')]
ax.legend(handles=handles, frameon=False, fontsize=8, loc='upper left', bbox_to_anchor=(1.01, 1), labelcolor=INK2)
f.tight_layout(); f.savefig(out + '-path.png', dpi=160); plt.close(f)
print(open(out + '-answer.txt').read())
print(f"paths: {len(keep)} reads kept of {N}; evidence read {sum(d in n_of for d in ans['gold'])} of {len(ans['gold'])}; "
      f"depth up to {max(depth[d] for d in keep)}")
