# Generator instructions (given verbatim to each blind generator subagent)

You are writing test questions for a system that inspects a search question
before it is run against a document store. The system flags question types
that a plain similarity search handles badly.

Domain: {DOMAIN_DESCRIPTION}

For EACH kind listed below, write 6 questions that a real person might type
into a search box over this store, and that clearly exhibit that kind. Vary:
length, phrasing, formality, which people/things are named, and how obvious
the kind is (include 2 that are subtle but still clearly the kind). Do not
reuse a sentence template across questions. Do not mention the kind's name.
A question may incidentally exhibit other kinds too; that is fine, but the
target kind must clearly apply.

{KINDS: code + definition}

{IF PLAIN:} Also write 40 plain questions a person might ask this store that
are direct, specific lookups: they name what they want, are about the store's
subject, and ask for one thing. Vary them widely.

Output JSONL only, one object per line:
{"domain": "...", "target": "<CODE or NONE>", "question": "..."}

## Values stage

For EACH per-passage kind below, write 6 items: a question someone asked the
store, and a passage (40-120 words, in the store's own register: diary prose for
dracula, ticket or postmortem prose for eng) that a search returned for it and
that clearly exhibits the kind. Also write 15 plain items whose passage directly
and fully answers its question, first-hand, with no pointer, hedge or
instruction in it. For CONFLICT write 10 items with a question, a passage and an
`other` passage that answer the question differently, and 10 where both
passages agree.

{"domain": "...", "target": "<CODE or NONE>", "question": "...", "passage": "...", "other": "... (CONFLICT items only)"}
