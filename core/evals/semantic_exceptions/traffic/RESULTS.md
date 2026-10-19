# Real traffic through the query tool (18 Oct)

## Run 1

This was the first run of the query log on traffic. The tool was the MCP `query` tool, the agent search path, against the disposable Dracula stack (extension 0.2.22, `sx-nav-db` and `sx-nav-rest`). Two servers ran side by side. One was in `shadow`, which computes the exceptions and shows nothing; the other was in `on`. Each wrote a `QueryEvent` log. Eight blind Haiku users each got the same eight tasks (`../navigate/users/TASKS.md`) and the same prompt, which differed only in the server URL. Four users drove `shadow` and four drove `on`, through `ask.py`, with one session per task. `traffic.py` then read the logs and had Jev judge each pair of a query and the one after it. `run1-report.json` is the summary. The logs are not committed.

| arm | queries | fired on | retry after raised | retry after silent | next query went where the guidance pointed |
|---|---|---|---|---|---|
| shadow | 128 | 45% | 0.67 | 0.77 | 0.70 (never shown) |
| on (shown) | 81 + 11 failed | 54% | 0.89 | 0.87 | 0.75 |

- **Showing the exceptions did not help on this store, and the answers may have been worse.** My own grading against `KEY.md` is rough and was not blind: about 11.5/32 for the shadow users and 6.25/32 for the on users. The on users also ran fewer queries. Through MCP this store answers only TEXT (SEARCH and SEMANTIC need an embedding the tool never sends), and its rows carry no date or narrator. So "split the question", "filter on an exact field" and "aggregate over the full set" point at moves this store cannot make. Three on users said as much ("useful but could not be acted on"), and they stopped sooner. This is four users per arm in one run, so it is a signal, not a result.
- **Agents mostly reach the advice on their own.** In shadow, 70% of the next queries already went where the unshown guidance pointed, against 75% when it was shown.
- **"Retry" cannot discriminate when a session is one task.** 67–89% of next queries were second attempts in both arms, so the lift came out near 1 (0.87 in shadow) and says nothing. The log now records row ids, and `traffic.py` reports **gain**: the share of the next query's records that the session had not seen. That outcome can differ between arms. Run 1 predates it.
- **The receipt caught a deployment fault on the first query.** `ran: false, CredentialRefused` meant the server had the Jev key with no origin bound to it. The exceptions were silently absent until the receipt said why.
- **Warnings repeated on every query.** The query tool did not apply `Report.novel`, so CONJUNCTION came back every time. It is now deduplicated per session (`X-P8-Session-Id`). The log keeps everything computed and records what was shown (`shown_codes`), and strict still refuses a repeated blended question.

## Run 2: after the fixes, graded blind

Run 2 used the merged tool: SEARCH and SEMANTIC embedded by the tool (#90), advice shown only where the caller can act on it (#91, #93), and MISSING_REFERENT at 0.90 (#92). The store now let callers read the source's table, so the SQL remedies were real. The setup was otherwise as before: 8 blind Haiku users, 4 per arm, with identical prompts except for the URL and id. Jev graded every answer against `KEY.md` without seeing the arm (`grade.py`). Before the run, the grader was checked: the key itself scores 7.98/8, wrong answers 0.19, and "not found" 0.03. Results are in `run2-grades.json` and `run2-report.json`.

| arm | users' scores (of 8) | mean | queries | fired on | next query went where the guidance pointed |
|---|---|---|---|---|---|
| shadow | 2.30, 4.51, 1.79, 1.56 | 2.54 | 97 | 32% | 0.43 (never shown) |
| on | 1.93, 1.30, 2.49, 4.47 | 2.55 | 108 | 38% | 0.60 |

- **Showing the exceptions changed nothing measurable: 2.55 against 2.54.** With four users per arm, a difference smaller than one user's spread cannot be seen.
- **Whether a user found the source's table decided the score.** The two best users, S2 at 4.51 (shadow) and O4 at 4.47 (on), read `sx.passages` with SQL for most of their queries (24 and 23). They were the only two to get task 7 right (Lucy's 12 September diary entry) and task 6 (26 July, Mina). Every other user stayed with ranked search and scored 1.3–2.5.
- **The exceptions did not lead anyone to SQL.** O4 switched on its third query with no exception shown just before, and S2 switched in shadow. The tool's description (`describe` lists SQL mode) is what led them there.
- **The advice that should have pointed there failed.** NEGATION's move said `SCHEMA "sql" FROM <source>` names the relation. But SCHEMA takes a relation, not a source, so `FROM dracula` lists nothing. O2 followed it and concluded that "the Dracula text is not reachable via SQL". It was the same mistake the probe made, written into the advice.
- **The layer does not predict struggle here.** In shadow, a query that raised something was followed by a retry less often than one that did not (lift 0.50). It was followed by slightly more new evidence (gain 0.87 against 0.71). So the kinds fire on hard questions, and the retry outcome is driven by the task, not by the exception.
- **The harness, not the layer, cost every arm points.** SEMANTIC returns chunk ids with no text, so its hits cannot be read. `ask.py` cut rows at 500 characters, and the cut hid date headings and key sentences in both arms.

## What this changes

On a capable store the decisive move is a capability: "this source's full text is the table sx.passages (key, document, source, time, content); exact questions go to SQL over it". An exception is worth showing when it carries that move concretely, naming the relation and its columns, rather than a general remedy. Run 3 needs four things: the advice names the relation; SEMANTIC returns the text of its hits; `ask.py` stops cutting rows; and more users per arm, because four cannot separate a small effect from who happens to find SQL.

## What run 1 changed

Advice has to be grounded in what the repository can do. The navigation round (`../navigate`) had a repository whose `actions` named its own commands, and users there were helped. Here the remedies name moves the store lacks, and the users were not helped. The next run needs three changes: the query tool's actions bound to p8ql moves this deployment supports, kinds whose remedy is unavailable kept quiet, and gain as the outcome.

## What surprised us

- **I expected shown exceptions to help a weak model, as they did in the navigation round.** They may have made it give up earlier. The difference is whether the advice can be acted on in the tool at hand.
- **In shadow, agents already go where the guidance points 70% of the time.** The value of an exception is in the other 30%, and on a store that cannot act on it, there is none.
