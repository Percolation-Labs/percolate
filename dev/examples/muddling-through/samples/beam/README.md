# BEAM, two conversations

Two conversations from BEAM, a benchmark of long-term memory in chat assistants, prepared for the Muddling Through
walkthrough:

- **1M:22**: 1,101 exchanges over 10 sittings. The walkthrough's explained miss, the ladder question, comes from it.
- **1M:35**: 1,058 exchanges over 10 sittings. On `1M:35:event_ordering:0` the walk clearly beats search.

The sample carries none of BEAM's text. `harness/beam_fetch.py` downloads BEAM's million-token split from Hugging Face at
a pinned revision, checks its sha256, and writes three files here: `texts.jsonl`, one exchange per line as `percolate
sample load` registers it; `questions.jsonl`, the 36 questions on these two conversations, each with its evidence as
document keys (`beam:1M:22/73` is exchange 73 of 1M:22); and `question-texts.jsonl`, each question
by uri `question:<qid>`, without its answer key, which `harness/labels.py` reads from `questions.jsonl` for the
evaluation functions. They follow the walk study's rules on the same file, and match its copy exactly.

What ships here is ours: `vectors.jsonl`, the bge-small vector the stack's own worker gave each piece, with the sha256
of the piece's text, so the download gets its vectors only where its text is the text they were made from
(`harness/vectors.py`); and `replay/`, every P Jev (jev-1.13.0) gave the workflow walk on the three step questions,
1M:35:event_ordering:0, 1M:22:multi_session_reasoning:1 and 1M:22:knowledge_update:1, exported with
`aiq.walk_verdicts(run)`, so a reader replays those walks offline at $0.

## Licence and credit

The data is BEAM's, and so is the licence: **CC BY-SA 4.0** (https://creativecommons.org/licenses/by-sa/4.0/). This
directory, as data derived from BEAM, carries the same licence; the code that loads and walks it does not.

> Mohammad Tavakoli et al., "Beyond a Million Tokens: Benchmarking and Enhancing Long-Term Memory in LLMs", ICLR 2026.
> arXiv:2510.27246. Dataset: https://huggingface.co/datasets/Mohammadta/BEAM

Changes from the original: each user turn's trailing `->-> n,m` plan index is removed from `terms_text`, the text a
walk tags, and from every piece. The index is BEAM's generator's (sitting, plan step), and plan step predicts which
exchanges BEAM's questions cite, so no decider may read it (REM-1240). Each piece's vector is still matched by the
text the study embedded, index included, so the vectors and search are the study's.
