-- AGENTIC SURFACE -- the manifest that removes what it does not mention.
--
-- `agentic.apply_plugin` is the only call in this system that DELETES rows as
-- its ordinary behaviour. That is deliberate and it is what makes a plugin
-- removable: anything stamped with a plugin's name and absent from its manifest
-- is pruned. It also had no test of any kind, which is a strange place for the
-- coverage to stop.
--
-- Written after walking an internal journey evaluation (J2, act 8) as a user rather than as its
-- author. Every assertion below is a thing that walk actually did, in the order
-- it did it, and each one is a way the prune can be right or can be a quiet
-- deletion somebody discovers later.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- ---------------------------------------------------------------
-- 1. A KEY NOBODY READS IS REFUSED, BECAUSE PRUNE MAKES IT DANGEROUS.
--
-- A misspelt key is not a no-op. It declares nothing under that heading, and a
-- manifest prunes to match what it declares -- so `agnets` on an installed
-- plugin removes every agent the plugin had. Measured before the refusal
-- existed: `{"skils": [...], "agnets": [...]}` returned
-- `{"agents": [], "skills": [], "removed": []}` and created a plugins row, and
-- re-applying an installed plugin with `agnets` misspelt returned
-- `{"removed": ["agent:case-officer"]}` -- a real deletion, reported as though
-- it had been asked for.
-- ---------------------------------------------------------------
do $$
declare v_err text; v_allowed boolean;
begin
    v_allowed := false;
    begin
        perform agentic.apply_plugin($j${
            "name": "t-p-typo", "version": "1.0.0",
            "skils": [{"name": "t-p-never", "description": "x", "content": "y"}]
        }$j$::jsonb);
        v_allowed := true;
    exception when others then v_err := sqlerrm;
    end;
    if v_allowed then
        raise exception
            'a manifest with a misspelt key was accepted. It installs nothing under '
            'that key and prunes everything the correct key installed.';
    end if;
    if v_err not like '%skils%' then
        raise exception 'the refusal does not name the offending key: %', v_err;
    end if;
    if v_err not like '%Nothing was changed%' then
        raise exception 'the refusal does not say the manifest was not applied: %', v_err;
    end if;

    -- and it refused BEFORE writing anything, which is the whole point of
    -- refusing rather than reporting.
    if exists (select 1 from agentic.plugins where name = 't-p-typo') then
        raise exception 'the refused manifest still created a plugins row';
    end if;
end $$;

-- ---------------------------------------------------------------
-- 2. `workflows` IS THE KEY PEOPLE WILL REACH FOR, and it is not one.
--
-- "Bundle the pipeline and the agent that reads it" is the obvious thing to
-- want, and J2 Act 8 asks for exactly that. A plugin bundles servers, skills
-- and agents; a workflow is defined by workflow.define_yaml and carries no
-- plugin stamp. Before the refusal this returned success and installed no
-- pipeline, so the bundle a reader believed was complete was not.
-- ---------------------------------------------------------------
do $$
declare v_err text; v_allowed boolean;
begin
    v_allowed := false;
    begin
        perform agentic.apply_plugin($j${
            "name": "t-p-wf", "version": "1.0.0",
            "workflows": [{"name": "t-p-pipeline", "spec": {"steps": []}}]
        }$j$::jsonb);
        v_allowed := true;
    exception when others then v_err := sqlerrm;
    end;
    if v_allowed then
        raise exception
            'a manifest carrying "workflows" was accepted and silently bundled no '
            'workflow -- the reader believes the pipeline travels with the plugin';
    end if;
    if v_err not like '%workflows%' then
        raise exception 'the refusal does not name the key: %', v_err;
    end if;
end $$;

-- ---------------------------------------------------------------
-- 3. THE PRUNE REPORTS WHAT IT REMOVED.
--
-- This is the property that keeps prune from being silent data loss, and it is
-- asserted from the RETURNED ENVELOPE rather than by diffing the tables --
-- because an operator only ever sees the envelope. A prune that removes
-- correctly and reports nothing is indistinguishable, at the call site, from
-- one that removed nothing.
-- ---------------------------------------------------------------
do $$
declare v_res jsonb;
begin
    perform agentic.apply_plugin($j${
        "name": "t-p-bundle", "version": "1.0.0",
        "skills": [{"name": "t-p-keep", "description": "kept", "content": "..."},
                   {"name": "t-p-drop", "description": "dropped next time", "content": "..."}]
    }$j$::jsonb);

    if not exists (select 1 from agentic.skills where name = 't-p-drop' and plugin = 't-p-bundle') then
        raise exception 'the bundle did not install what it declared';
    end if;

    -- the same plugin, one skill withdrawn
    v_res := agentic.apply_plugin($j${
        "name": "t-p-bundle", "version": "1.1.0",
        "skills": [{"name": "t-p-keep", "description": "kept", "content": "..."}]
    }$j$::jsonb);

    if exists (select 1 from agentic.skills where name = 't-p-drop') then
        raise exception 'a skill absent from the manifest survived the prune';
    end if;
    if not (v_res->'removed' @> '["skill:t-p-drop"]'::jsonb) then
        raise exception
            'the prune removed t-p-drop and did not say so. The envelope is the only '
            'place an operator learns what a manifest deleted -- it returned: %', v_res;
    end if;
end $$;

-- ---------------------------------------------------------------
-- 4. NOTHING OUTSIDE THE BUNDLE MOVES.
--
-- The failure this guards is reaching for a plugin name somebody else is using.
-- It shipped once: docs/src/skills.md documented an example under the harbour
-- sample's own plugin name, which deleted the sample's skill on any reader's
-- stack. A row with no plugin stamp, or another plugin's stamp, is not the
-- manifest's business.
-- ---------------------------------------------------------------
do $$
declare v_before int; v_after int;
begin
    perform agentic.upsert_skill($j${
        "name": "t-p-unowned", "description": "belongs to nobody", "content": "..."}$j$::jsonb);
    perform agentic.apply_plugin($j${
        "name": "t-p-other", "version": "1.0.0",
        "skills": [{"name": "t-p-others", "description": "another plugin's", "content": "..."}]
    }$j$::jsonb);

    select count(*) into v_before from agentic.skills
    where name in ('t-p-unowned', 't-p-others');

    -- a manifest that declares nothing at all, under a third name
    perform agentic.apply_plugin($j${"name": "t-p-empty", "version": "1.0.0"}$j$::jsonb);

    select count(*) into v_after from agentic.skills
    where name in ('t-p-unowned', 't-p-others');
    if v_after <> v_before then
        raise exception
            'applying one plugin removed rows belonging to another, or to nobody: '
            '% before, % after', v_before, v_after;
    end if;
end $$;

-- ---------------------------------------------------------------
-- 5. A SKILL AN AGENT STILL PINS CANNOT BE PRUNED OUT FROM UNDER IT.
--
-- The referential check, asserted because it is what turned the misspelt-key
-- case from data loss into an error during the J2 walk. Without it, `skils`
-- would have removed a skill that a surviving agent still names.
-- ---------------------------------------------------------------
do $$
declare v_err text; v_allowed boolean;
begin
    perform agentic.apply_plugin($j${
        "name": "t-p-pin", "version": "1.0.0",
        "skills": [{"name": "t-p-pinned", "description": "pinned", "content": "..."}],
        "agents": [{"name": "t-p-holder", "skills": ["t-p-pinned"],
                    "system_prompt": "holds a skill"}]
    }$j$::jsonb);

    v_allowed := false;
    begin
        -- the agent stays, the skill it names is withdrawn
        perform agentic.apply_plugin($j${
            "name": "t-p-pin", "version": "1.1.0",
            "agents": [{"name": "t-p-holder", "skills": ["t-p-pinned"],
                        "system_prompt": "holds a skill"}]
        }$j$::jsonb);
        v_allowed := true;
    exception when others then v_err := sqlerrm;
    end;
    if v_allowed then
        raise exception
            'a skill was pruned while an agent in the same manifest still named it -- '
            'the agent now points at nothing and no error said so';
    end if;
    if v_err not like '%t-p-holder%' then
        raise exception 'the refusal does not name what is holding it: %', v_err;
    end if;
    if exists (select 1 from agentic.skills where name = 't-p-pinned' and plugin is null) then
        raise exception 'the refused prune orphaned the skill instead of leaving it alone';
    end if;
end $$;


-- ---------------------------------------------------------------
-- 6. AN UNINSTALLED PLUGIN READS AS UNINSTALLED, AND ITS ROW STAYS.
--
-- The empty manifest is the uninstall, and it leaves the plugins row for
-- provenance (plugins.md §9). Before `plugins_api.installed` an operator could
-- not tell that row from a plugin that installs something without joining out
-- to three tables (REM-250, measured on 0.1.5 walking journey J2, act 8).
-- ---------------------------------------------------------------
do $$
begin
    perform agentic.apply_plugin($j${
        "name": "t-p-inventory", "version": "1.0.0",
        "skills": [{"name": "t-p-inv-skill", "description": "x", "content": "y"}]
    }$j$::jsonb);
    if not (select installed from agentic.plugins_api where name = 't-p-inventory') then
        raise exception 'a plugin with a skill installed reads as not installed';
    end if;

    perform agentic.apply_plugin('{"name": "t-p-inventory", "version": "1.1.0"}'::jsonb);
    if not exists (select 1 from agentic.plugins_api where name = 't-p-inventory') then
        raise exception 'uninstalling deleted the plugins row, and with it the provenance';
    end if;
    if (select installed from agentic.plugins_api where name = 't-p-inventory') then
        raise exception 'a plugin with nothing under it still reads as installed';
    end if;
end $$;

rollback;
