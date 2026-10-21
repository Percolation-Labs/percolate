-- A MODERATOR ACTS ONLY ON A COMMENT THEY CAN READ (REM-1113).
--
-- engagement.moderate_comment withdrew any comment by id once rbac.require
-- allowed engagement:moderate, and require honours a grant held in the
-- request's org. So a moderator granted in org A withdrew a comment on org B's
-- private revision. Asserted here:
--   1. an org-A moderator who cannot read org B's private work gets "Comment
--      not found" for its comment, the same answer as for an id that does not
--      exist, and the comment stays;
--   2. a moderator who can read it (granted in org B, a member) withdraws it.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

\set owner_b   '''00000000-0000-4000-8000-000000111301'''
\set mod_a     '''00000000-0000-4000-8000-000000111302'''
\set mod_b     '''00000000-0000-4000-8000-000000111303'''
\set org_a     '''00000000-0000-4000-8000-000000111310'''
\set org_b     '''00000000-0000-4000-8000-000000111311'''
\set work_b    '''00000000-0000-4000-8000-000000111320'''
\set rev_b     '''00000000-0000-4000-8000-000000111321'''
\set comment_b '''00000000-0000-4000-8000-000000111330'''
\set as_mod_a 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000111302","org_id":"00000000-0000-4000-8000-000000111310"}''; set local role authenticated;'
\set as_mod_b 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000111303","org_id":"00000000-0000-4000-8000-000000111311"}''; set local role authenticated;'

begin;
insert into rbac.users (id, email, status) values
    (:owner_b, 'rem1113-owner-b@example.test', 'active'),
    (:mod_a,   'rem1113-mod-a@example.test',   'active'),
    (:mod_b,   'rem1113-mod-b@example.test',   'active');
insert into rbac.orgs (id, slug, name) values (:org_a, 'rem1113-org-a', 'Org A'), (:org_b, 'rem1113-org-b', 'Org B');
insert into rbac.org_members (org_id, user_id) values (:org_a, :mod_a), (:org_b, :owner_b), (:org_b, :mod_b);
insert into rbac.roles (name) values ('rem1113_moderator');
insert into rbac.role_permissions (role, resource, action) values ('rem1113_moderator', 'engagement', 'moderate');
insert into rbac.grants (user_id, role, org_id, basis) values
    (:mod_a, 'rem1113_moderator', :org_a, 'operator'),
    (:mod_b, 'rem1113_moderator', :org_b, 'operator');
insert into rbac.user_roles (user_id, role) values (:mod_a, 'rem1113_moderator'), (:mod_b, 'rem1113_moderator');
insert into research.works (id, public_id, owner_id, org_id, visibility)
values (:work_b, 'rem1113-work', :owner_b, :org_b, 'org');
insert into research.revisions (id, work_id, number, label, schema_version, document, content_hash, actor_id, actor_kind)
values (:rev_b, :work_b, 1, 'draft-1', '0.1', '{}'::jsonb, md5('rem1113'), :owner_b, 'person');
insert into engagement.comments (id, revision_id, author_id, body)
values (:comment_b, :rev_b, :owner_b, 'Org B internal note');

create function pg_temp.refused(p_sql text, p_like text) returns void language plpgsql as $$
begin
    execute p_sql;
    raise exception 'accepted, and should have been refused: %', p_sql;
exception when others then
    if sqlerrm not like p_like then raise; end if;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

-- 1. Org A's moderator.
:as_mod_a
do $$
begin
    if research.readable('00000000-0000-4000-8000-000000111320') then
        raise exception 'fixture: the org-A moderator can read org B''s work, so this proves nothing';
    end if;
end $$;
select pg_temp.refused($q$select engagement.moderate_comment('00000000-0000-4000-8000-000000111330', 'from org A')$q$,
                       'Comment not found');
select pg_temp.refused($q$select engagement.moderate_comment('00000000-0000-4000-8000-0000001113ff', 'no such comment')$q$,
                       'Comment not found');
reset role;
do $$
begin
    if (select withdrawn_at from engagement.comments where id = '00000000-0000-4000-8000-000000111330') is not null then
        raise exception 'a moderator who cannot read the work withdrew its comment';
    end if;
end $$;

-- 2. Org B's moderator.
:as_mod_b
select engagement.moderate_comment(:comment_b, 'moderated in org B');
reset role;
do $$
begin
    if (select withdrawn_by from engagement.comments where id = '00000000-0000-4000-8000-000000111330')
       is distinct from '00000000-0000-4000-8000-000000111303' then
        raise exception 'a moderator who can read the work could not withdraw its comment';
    end if;
end $$;

rollback;

\echo research/43: a moderator acts only on a comment they can read, and an unreadable one is not found
