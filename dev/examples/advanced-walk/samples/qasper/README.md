# QASPER: questions whose answer search buries

QASPER is a set of questions that NLP practitioners asked about research papers after reading only the title and
abstract. Other practitioners answered them from the full text and marked the paragraphs that hold each answer.
Pool every paragraph of the 281 development papers into one corpus, 13,547 paragraphs, and some of those answers
sink: search ranks a paragraph the answer needs past its first hundred results.

**The questions (questions.jsonl).**
- **14 buried past 100** (`type: buried-past-100`): each has at least one required paragraph that search ranks past
  its 100th result, so search alone cannot read it within a budget of 100 reads. 22 such paragraphs in all.
- **3 that search reads** (`type: search-reads-it`): every required paragraph within search's first 100. They are
  there to show what a walk costs where search is enough.

Each question's text is `<paper title>: <question>`, because the asker had read the title, and the corpus holds 281
papers. `gold` lists the paragraphs the first annotator cited. `other_annotators` lists any further ones cited.
The gold never enters the database: question-texts.jsonl carries each question's words alone.

**Loading.**

    python3 harness/qasper_fetch.py samples/qasper    # 11 MB down; 13,547 vectors made here, ~15 min on a CPU
    percolate sample load samples/qasper
    percolate walk index --source qasper

The fetch script downloads QASPER's train-dev release from AllenAI's bucket and checks it against a pinned sha256.
It writes one document per paragraph, and embeds each with BAAI/bge-small-en-v1.5, the model the stack's worker
runs, so loading takes seconds rather than hours of the stack's rate-limited embedding queue. Measured on a busy
laptop: the fetch and embedding took 16 minutes, and `sample load` stored all 13,547 paragraphs with their vectors
in under a minute. The chunk is each paragraph's title line, a blank line and its text, the text the lab's search
ranks were measured on. `--no-vectors` skips the embedding.

**What to expect.** Measured in the lab with a stand-in judge, under the walk rule this tutorial turns on (each
round's top three leads plus any the judge scores at one half or more, highest first, at most ten documents each):
- on the 14 buried questions, the walk read 35 of 40 required paragraphs against 18 for search alone, including 17 of
  the 22 past search's 100th result;
- it completed 10 of the 14 questions, where search completed none;
- on the 3 others it read what search reads, 5 of 5.
Your numbers depend on the judge you run, so treat these as a direction, not a target.

Licence: CC BY 4.0 (see LICENSE).
