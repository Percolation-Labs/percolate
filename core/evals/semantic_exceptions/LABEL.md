# Labeller instructions (given verbatim to each blind labeller subagent)

You are labelling search questions (or question + passage pairs) for a system
that inspects them. For each item, decide which of the kinds below CLEARLY
apply. Apply a kind only if a careful reader would agree it applies without
argument. Ambiguous is no. An item can have zero, one or several kinds.

You are not told why an item was written. Judge each item on its own text.

Store description, for the domain the item is in: {DOMAIN_DESCRIPTION}

{KINDS: code + definition}

Output JSONL only, one line per item, in input order:
{"id": "...", "kinds": ["CODE", ...]}
