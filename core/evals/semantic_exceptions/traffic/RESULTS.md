# Real traffic through the query tool: run 1 (18 Oct)

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

## What this changes

Advice has to be grounded in what the repository can do. The navigation round (`../navigate`) had a repository whose `actions` named its own commands, and users there were helped. Here the remedies name moves the store lacks, and the users were not helped. The next run needs three changes: the query tool's actions bound to p8ql moves this deployment supports, kinds whose remedy is unavailable kept quiet, and gain as the outcome.

## What surprised us

- **I expected shown exceptions to help a weak model, as they did in the navigation round.** They may have made it give up earlier. The difference is whether the advice can be acted on in the tool at hand.
- **In shadow, agents already go where the guidance points 70% of the time.** The value of an exception is in the other 30%, and on a store that cannot act on it, there is none.
