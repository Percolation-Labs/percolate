-- AGENTIC SURFACE -- one real turn, driven over HTTP against this database.
--
-- requires-service: agent
-- drives: agent-turn
-- requires-core: 0.1.9
--
-- WHAT THIS IS FOR, and it is the only file in this suite that leaves the
-- database to find out. Every other agentic file asserts about rows: the
-- binding, the conversation plane, the message boundary. All of them pass on a
-- tree where `agent serve` cannot open a session at all, because none of them
-- ever starts it. That is the gap this file closes -- a change to the agentic
-- schema, to surface.sql's build order or to the seeded agents could pass
-- every gate here and break the shipped stack, and the only thing that noticed
-- was somebody running the workbench by hand.
--
-- WHAT IT DOES NOT DO. It does not assert an answer. A turn that reaches a
-- model needs a provider key, and a gate that needs one is a gate that is
-- skipped on every machine that does not have one -- and CI must not have one.
-- So the claim here is HOW FAR THE TURN GOT: a verified token, a session
-- opened as an ordinary caller, the agent row resolved, the run written. All
-- of that is this repository's schema, and all of it happens before the first
-- byte goes to a provider. The behaviour past that point is
-- percolate-core's `percolate-core/dev/verify.py` and is deliberately not duplicated here
-- (specs/agentic/sequence.md: "two artifacts proving the same thing").
--
-- THE THREE OUTCOMES, and the middle one is why this file is not a one-liner.
-- `dev/tests/drive/agent-turn.sh` records the response and the runtime's log
-- rather than a verdict, because there are three things a turn can do against
-- a pinned image and only one of them is a defect:
--
--   * it opens a session      -- the runtime and this schema agree
--   * it refuses at set_config -- the KNOWN incompatibility below, which is a
--                                 fact about the pin and not about this commit
--   * anything else            -- a regression, and what this file is for
--
-- Asserting "status = 200" would have made the second indistinguishable from
-- the third, which is the assertion shape that makes a suite unreadable on the
-- one day it matters.

\set ON_ERROR_STOP on

begin;

do $$
declare
    v      public.p8_test_agent_turn;
    v_st   int;
    v_nerr int;
    v_last text;
    v_msg  text;
begin
    select * into v from public.p8_test_agent_turn
     order by driven_at desc limit 1;
    if v is null then
        raise exception
            'no turn was driven -- dev/tests/run.sh should have run '
            'dev/tests/drive/agent-turn.sh for this file''s `-- drives:` line';
    end if;
    raise notice 'turn driven against % (build %)', v.image, v.build;

    v_st := (v.result->>'status')::int;

    -- ---------------------------------------------------------------
    -- 1. THE RUNTIME ANSWERED AT ALL.
    --
    -- -1 is the driver's own marker for "the request did not complete":
    -- a connection refused, a timeout, a process that died mid-turn. The
    -- runtime had already answered /_build by this point, so this is the
    -- turn itself failing to be served rather than a service that never
    -- came up -- which run.sh's `-- requires-service:` axis reports
    -- separately, and as a skip rather than as this.
    -- ---------------------------------------------------------------
    if v_st = -1 then
        raise exception
            'the turn never completed: %. The runtime answered /_build, so '
            'this is the turn, not the service.', v.result->>'detail';
    end if;

    -- ---------------------------------------------------------------
    -- 2. IT WAS NOT REFUSED FOR WHO WE ARE.
    --
    -- A 401 or a 403 here is not a provider problem and not a missing key:
    -- it is the token this suite mints no longer being one the runtime
    -- accepts, or `agentic.start_run` refusing a caller it used to allow.
    -- Both are exactly the regression this file exists for, and both would
    -- otherwise be invisible until somebody opened the workbench.
    -- ---------------------------------------------------------------
    if v_st in (401, 403) then
        raise exception
            'the turn was refused %: %. The caller is the seeded user every '
            'other file in this surface reads as, so this is an authorization '
            'regression rather than a configuration problem.',
            v_st, v.result->>'detail';
    end if;

    -- ---------------------------------------------------------------
    -- 3. A 500 MAY ONLY BE THE ONE INCOMPATIBILITY WE KNOW ABOUT.
    --
    -- percolate-core through 0.1.8 writes the role BEFORE the claims in
    -- `core/identity.as_caller` -- `set local role authenticated`, then
    -- `select set_config('request.jwt.claims', ...)`, so the second statement is
    -- refused and no turn can open a session.
    --
    -- WHERE THE REVOKE ACTUALLY LIVES, because it is not where it looks. The
    -- extension does NOT perform it -- `dev/image-init/00-superuser.sql` does,
    -- with the image. What percolate 0.2.0 does is REFUSE TO INSTALL OR UPGRADE
    -- while `authenticated`, `web_anon` or `api_viewer` can still call it
    -- ("including on the upgrade of a database that predates the rule, which
    -- would otherwise complete with the door open").
    --
    -- That distinction is what makes the pairing a hard constraint rather than
    -- a coincidence: there is no database running extension 0.2.0 WITHOUT the
    -- revoke, because such a database is refused the upgrade. So every 0.2.0
    -- database breaks core 0.1.8, not merely the ones whose operator
    -- remembered to re-run the superuser step. percolate-core main has the order the other way
    -- round and says why; it is unreleased. REM-135 carries the pairing
    -- constraint that follows -- extension 0.2.0 requires percolate-core
    -- 0.1.9 or newer -- because a deferral in a test file is not a thing the
    -- release path reads.
    --
    -- MEASURED, not inferred: a 0.1.6 database answers `t` to
    -- has_function_privilege('authenticated', 'set_config', 'execute') and a
    -- database built from this tree answers `f`, so this is a break that
    -- arrives WITH extension 0.2.0 rather than one that is already shipping.
    --
    -- IT EXPIRES ON A VERSION, NOT ON A LOG LINE (REM-86). The notice below
    -- is legal only while the runtime that drove the turn is older than this
    -- file's `requires-core` header, 0.1.9, the first core that writes the
    -- claims before the role. dev/tests/run.sh reads the image the driver
    -- recorded and FAILS a CORE-DEFERRED from a runtime at or past it. Until
    -- 2026-09-13 the only condition was the log naming set_config, with no
    -- version at all, so a 0.1.9 or later runtime refused at set_config for a
    -- new reason would have been reported as the old one.
    -- ---------------------------------------------------------------
    if v_st >= 500 then
        if v.agent_log like '%permission denied for function set_config%' then
            raise notice
                'CORE-DEFERRED: the turn was refused at set_config, against '
                'image %. WHAT THAT MEANS IS NOT MEASURED HERE: this reports '
                'the refusal it saw, not a cause. The known cause is a runtime '
                'that writes the role before the claims, which cores through '
                '0.1.8 do -- but this message used to ASSERT that of whatever '
                'image was pinned, by interpolating the pin into the sentence, '
                'and it said it of 0.1.9, which orders claims first '
                '(identity.py:207 before :210). A template that reads as an '
                'observation sends the next reader to fix something already '
                'fixed. Read the runtime log below and check the ordering in '
                'the image named, rather than trusting this line.', v.image;
            return;
        end if;
        -- One E-string rather than a plain literal continued into an
        -- E-literal: Postgres concatenates adjacent literals across a newline
        -- only when they are the same kind, and mixing them is a syntax error
        -- pointing at the second one.
        raise exception E'the turn failed with % and NOT at the known set_config ordering: %\n--- the runtime said ---\n%',
            v_st, v.result->>'detail', v.agent_log;
    end if;

    -- ---------------------------------------------------------------
    -- 4. THE TURN OPENED A SESSION, AND THE STREAM SAYS SO.
    --
    -- A 200 IS NOT A PASS, and this is the assertion that took three goes to
    -- get right. AG-UI reports failure IN BAND: the response is 200, the
    -- stream is well formed, and the only event in it is a RUN_ERROR. While
    -- this file asserted `status = 200` and `events > 0` it went green on
    -- three separate broken turns in a row -- a session refused at set_config,
    -- an agent row that had been renamed out from under it, and a caller
    -- without `agents:invoke`. Each looked exactly like health from outside.
    --
    -- So the claim is about the events, and RUN_STARTED is the one that
    -- carries it: the runtime resolved the agent row, opened a run against
    -- THIS schema, and began. Everything the issue behind this file names --
    -- the agentic schema, surface.sql's build order, the seeded agents -- is
    -- upstream of that event and cannot produce it when broken.
    -- ---------------------------------------------------------------
    if v.result->>'session' is null then
        raise exception
            'the turn returned % and no X-P8-Session-Id header -- a client '
            'that loses the stream cannot reconnect to it', v_st;
    end if;

    if not exists (select 1 from jsonb_array_elements(coalesce(v.result->'events','[]'::jsonb)) e
                    where e->>'type' = 'RUN_STARTED') then
        raise exception E'the turn returned % and never emitted RUN_STARTED, so no run began.\n--- events ---\n%\n--- the runtime said ---\n%',
            v_st, jsonb_pretty(coalesce(v.result->'events','[]'::jsonb)), v.agent_log;
    end if;

    -- AND IT WROTE. MESSAGE_PERSISTED is the event that distinguishes a turn
    -- that reached the database from one that only reached the runtime, which
    -- is the whole point of running this here rather than in percolate-core.
    if not exists (select 1 from jsonb_array_elements(coalesce(v.result->'events','[]'::jsonb)) e
                    where e->>'type' = 'MESSAGE_PERSISTED') then
        raise exception E'the turn started and persisted no message -- it reached the runtime and not the database.\n--- events ---\n%',
            jsonb_pretty(coalesce(v.result->'events','[]'::jsonb));
    end if;

    -- ---------------------------------------------------------------
    -- 5. WITHOUT A PROVIDER KEY, THE TURN MAY STOP ONCE, AT THE PROVIDER.
    --
    -- THIS IS WHAT REPLACES "SKIP WHEN THERE IS NO MODEL KEY", and it is a
    -- stronger check than the skip would have been. A skip stands the whole
    -- file down on every machine without a key -- which is CI, always, and
    -- deliberately -- so the axis would have skipped everywhere and looked
    -- identical to success, which is the failure this file's own issue warns
    -- about in as many words.
    --
    -- The provider call is the LAST thing a turn does. Everything before it is
    -- this repository's: the token, the session, the agent row, the run, the
    -- persisted message. So the honest claim is "the turn got as far as the
    -- provider", and the way to assert it is to permit exactly that one error
    -- and no other.
    --
    -- DECIDED ON A FACT THE DRIVER HAS, NOT ON THE ERROR'S WORDING. This used
    -- to excuse any RUN_ERROR whose message matched
    -- `(_API_KEY|api_key|credential|LLM_API_KEY)` -- which also excuses a
    -- tool server's missing credential, a credential_ref that stopped
    -- resolving, or any failure whose text happens to name one. The driver
    -- knows whether it put a provider key into the runtime's environment and
    -- records it as `provider_key_supplied`. Without a key, the turn must stop
    -- at the provider: exactly one RUN_ERROR, and it is the last event, after
    -- the RUN_STARTED and MESSAGE_PERSISTED asserted above. With a key, or
    -- with the fact missing, no RUN_ERROR is permitted at all.
    --
    -- WHAT IT CANNOT SEE: with no key, a lone final RUN_ERROR raised by
    -- something other than the provider call is excused too. Nothing
    -- structured tells them apart. percolate-core's RunError carries only
    -- `status` and `message`, and sequencer._run_turn emits the same event
    -- for any exception from bind_tools, invoke_model, persist or
    -- maybe_chain; agentic.runs keeps only that text in state.error. The
    -- probe agent binds no tools, which removes the likeliest other cause.
    -- Closing it needs core to name the failing step on the event, and then
    -- this should assert that field.
    -- ---------------------------------------------------------------
    select count(*) filter (where e->>'type' = 'RUN_ERROR'),
           (array_agg(e->>'type' order by n desc))[1],
           (array_agg(e->>'message' order by n desc) filter (where e->>'type' = 'RUN_ERROR'))[1]
      into v_nerr, v_last, v_msg
      from jsonb_array_elements(coalesce(v.result->'events','[]'::jsonb)) with ordinality as t(e, n);
    if v_nerr > 0 then
        if coalesce((v.result->>'provider_key_supplied')::boolean, true) then
            raise exception E'the turn failed inside the stream, and the driver supplied a provider key (or did not record whether it did):\n  %\n--- the runtime said ---\n%',
                v_msg, v.agent_log;
        end if;
        if v_nerr > 1 or v_last <> 'RUN_ERROR' then
            raise exception E'with no provider key the turn may stop once, at the provider, as its last event; it emitted % RUN_ERROR(s) and ended with %.\n--- events ---\n%',
                v_nerr, v_last, jsonb_pretty(coalesce(v.result->'events','[]'::jsonb));
        end if;
        raise notice 'the turn reached the provider and stopped there (the driver supplied no key): %',
            left(v_msg, 90);
    end if;

    -- ---------------------------------------------------------------
    -- 6. AND THE ROWS ARE THERE, READ AS THE CALLER RATHER THAN AS THE OWNER.
    --
    -- `sessions_api`, THE VIEW, because that is what an ordinary caller has.
    -- `authenticated` holds SELECT on the view and nothing at all on the base
    -- table -- reading `agentic.sessions` here raised `permission denied for
    -- table sessions`, which is the right answer to the wrong question. An
    -- owner-side count would pass on a database whose policies hide a caller's
    -- own session from them, and that failure has a face: the history pane is
    -- empty for a conversation the user just had.
    -- ---------------------------------------------------------------
    perform set_config('request.jwt.claims',
                       json_build_object('sub', v.result->>'sub')::text, true);
    set local role authenticated;
    if not exists (select 1 from agentic.sessions_api
                    where id = (v.result->>'session')::uuid) then
        raise exception
            'the turn opened session % and the caller cannot see it through '
            'RLS -- their own conversation is invisible to them',
            v.result->>'session';
    end if;
    reset role;
    reset request.jwt.claims;

    raise notice 'a turn started, persisted its message, and its session is '
                 'readable through RLS by the caller who had it';
end $$;

rollback;
