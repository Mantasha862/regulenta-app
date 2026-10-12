-- REGULENTA AI — complete database schema for Supabase (Postgres 15+)
-- Part 1: tenancy, rulebook versioning, obligations, deadline engine, RLS
-- Part 2: platform roles, authorities/sources/monitoring, documents + evidence, change detection,
--         research queue with the approval guard, due-date history, reminders, notifications,
--         applicability explainer, freshness, storage policies
-- Tested on Postgres 16 with Supabase-style roles and storage stubs. Not yet applied to any project.
-- Contains NO rulebook data. Seed rules only through the review queue, with evidence.

-- ComplyTrack schema for Supabase (Postgres 15+)
-- Multi-tenant: every client record belongs to an org (a CS/law firm or a company).
-- The rulebook is global and read-only to tenants; changes go through a human review queue.

create extension if not exists pgcrypto;

-- ───────────── enums ─────────────
create type org_type        as enum ('firm','company');
create type member_role     as enum ('owner','admin','member','viewer');
create type law_code        as enum ('CA','LLP','SEBI','GST','LAB','TAX','FEMA','OTHER');
create type rule_kind       as enum ('fixed','event','recurring');
create type confidence      as enum ('high','medium','low');
create type rule_state      as enum ('draft','active','superseded','repealed','not_yet_effective','suspended');
create type obligation_status as enum ('upcoming','in_progress','filed','not_applicable','waived');
create type review_state    as enum ('pending','approved','rejected');

-- ───────────── helpers ─────────────
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

-- ───────────── tenancy ─────────────
create table orgs (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  type org_type not null,
  plan text not null default 'free',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table org_members (
  org_id  uuid not null references orgs(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role member_role not null default 'member',
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index on org_members (user_id);

-- security-definer helpers avoid recursive RLS on org_members
create or replace function is_org_member(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from org_members where org_id = p_org and user_id = auth.uid())
$$;
create or replace function can_write_org(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from org_members
                 where org_id = p_org and user_id = auth.uid()
                   and role in ('owner','admin','member'))
$$;
create or replace function is_org_admin(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from org_members
                 where org_id = p_org and user_id = auth.uid()
                   and role in ('owner','admin'))
$$;

-- ───────────── clients (entities being tracked) ─────────────
create table clients (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs(id) on delete cascade,
  name text not null,
  cin_or_llpin text,
  entity_type text not null,              -- 'private_ltd','public_ltd','opc','llp','section_8', ...
  fy_end_month smallint not null default 3 check (fy_end_month between 1 and 12),
  state text,                             -- state matters for labour, PT, S&E
  -- applicability facts used to match rules, e.g.
  -- {"listed":false,"small_company":true,"has_foreign_investment":true,"employees_over_20":true,"gst_registered":true}
  profile jsonb not null default '{}'::jsonb,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on clients (org_id);
create index clients_profile_gin on clients using gin (profile jsonb_path_ops);

-- ───────────── rulebook (global) ─────────────
-- Stable identity of a compliance; content lives in versions so history is never overwritten.
create table rules (
  id uuid primary key default gen_random_uuid(),
  rule_key text not null unique,          -- e.g. 'CA-AOC4', 'GST-GSTR3B'
  law law_code not null,
  form text not null,                     -- 'AOC-4', 'GSTR-3B', 'Reg 31'
  title text not null,
  created_at timestamptz not null default now()
);

create table rule_versions (
  id uuid primary key default gen_random_uuid(),
  rule_id uuid not null references rules(id) on delete cascade,
  version int not null,
  state rule_state not null default 'draft',
  kind rule_kind not null,
  -- law / evidence
  section_or_rule text,                   -- 'Companies Act 2013, s.137'
  authority text,                         -- 'MCA', 'SEBI', 'CBIC' ...
  applicability_text text,
  applies_when jsonb not null default '{}'::jsonb,   -- matched against clients.profile with @>
  frequency text,
  trigger_event text,                     -- for kind='event': 'AGM date', 'Allotment date'
  -- deadline definition (machine readable)
  schedule jsonb not null,                -- see generate_* functions below
  due_text text not null,                 -- human wording
  due_basis text,                         -- 'FY end', 'AGM', 'Event date', 'Month end' ...
  due_calculation text,
  penalty text,
  -- evidence
  source_url text,
  source_document text,
  source_date date,
  effective_from date,
  effective_until date,
  last_amended date,
  last_checked date,
  confidence confidence not null default 'low',
  notes text,
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  unique (rule_id, version)
);
-- only one active version per rule
create unique index one_active_version on rule_versions (rule_id) where state = 'active';
create index on rule_versions (state);

-- Sources consulted for a rule version (several can conflict)
create table rule_sources (
  id uuid primary key default gen_random_uuid(),
  rule_version_id uuid not null references rule_versions(id) on delete cascade,
  url text not null,
  title text,
  source_level smallint not null check (source_level between 1 and 4),  -- 1 = primary authority
  position_stated text,                   -- what this source says
  fetched_at timestamptz not null default now()
);
create index on rule_sources (rule_version_id);

-- AI-proposed changes wait here for human approval. The rulebook is never edited directly by AI.
create table rule_review_queue (
  id uuid primary key default gen_random_uuid(),
  rule_id uuid references rules(id) on delete set null,   -- null = proposed new rule
  proposed jsonb not null,                -- full proposed rule_versions row
  old_position text,
  new_position text,
  effective_date date,
  evidence jsonb not null default '[]'::jsonb,   -- [{url, title, level, quote}]
  conflict_note text,
  state review_state not null default 'pending',
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create index on rule_review_queue (state);

create table holidays (
  day date primary key,
  note text
);

-- ───────────── obligations (generated per client) ─────────────
create table events (                     -- a logged trigger that starts an event-based clock
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs(id) on delete cascade,
  client_id uuid not null references clients(id) on delete cascade,
  trigger_event text not null,            -- 'AGM date', 'Allotment date'
  event_date date not null,
  note text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index on events (client_id);

create table obligations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs(id) on delete cascade,
  client_id uuid not null references clients(id) on delete cascade,
  rule_version_id uuid not null references rule_versions(id),   -- exact rule text used, preserved for audit
  event_id uuid references events(id) on delete set null,
  period_label text not null,             -- 'Sep 2026', 'Q2 FY27', 'FY 2025-26', 'AGM 2026'
  due_date date not null,
  due_date_basis text,                    -- how the date was computed
  status obligation_status not null default 'upcoming',
  assignee uuid references auth.users(id),
  filed_on date,
  reference_no text,                      -- SRN / ARN
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (client_id, rule_version_id, period_label)
);
create index on obligations (org_id, due_date);
create index on obligations (client_id, status);

create table documents (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs(id) on delete cascade,
  client_id uuid references clients(id) on delete cascade,
  obligation_id uuid references obligations(id) on delete set null,
  storage_path text not null,             -- Supabase Storage object path
  file_name text not null,
  uploaded_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index on documents (org_id, client_id);

create table notifications (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs(id) on delete cascade,
  obligation_id uuid not null references obligations(id) on delete cascade,
  channel text not null check (channel in ('email','whatsapp','in_app')),
  send_on date not null,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  unique (obligation_id, channel, send_on)
);
create index on notifications (send_on) where sent_at is null;

create table audit_log (
  id bigint generated always as identity primary key,
  org_id uuid,
  user_id uuid,
  action text not null,
  entity text not null,
  entity_id uuid,
  detail jsonb,
  at timestamptz not null default now()
);
create index on audit_log (org_id, at desc);

-- updated_at triggers
create trigger t_orgs_upd        before update on orgs        for each row execute function set_updated_at();
create trigger t_clients_upd     before update on clients     for each row execute function set_updated_at();
create trigger t_obligations_upd before update on obligations for each row execute function set_updated_at();

-- audit status changes on obligations
create or replace function audit_obligation() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and (old.status is distinct from new.status or old.due_date is distinct from new.due_date) then
    insert into audit_log(org_id, user_id, action, entity, entity_id, detail)
    values (new.org_id, auth.uid(), 'update', 'obligation', new.id,
            jsonb_build_object('status', jsonb_build_array(old.status, new.status),
                               'due_date', jsonb_build_array(old.due_date, new.due_date)));
  end if;
  return new;
end $$;
create trigger t_obligation_audit after update on obligations for each row execute function audit_obligation();

-- ───────────── deadline engine ─────────────
-- schedule JSON shapes understood by the engine:
--   {"type":"monthly","day":11}                          day of the following month
--   {"type":"annual","month":9,"day":30}                 fixed day each year (in the year the FY ends or following; see note)
--   {"type":"dates","dates":["07-31","10-31","01-31"]}   list of MM-DD per year
--   {"type":"after_period","unit":"quarter","days":21}   N days after quarter end
--   {"type":"event","days":30,"day_type":"calendar"|"working","direction":1|-1}
-- Anything else (e.g. {"varies":true}) is skipped and must be handled by a human.

create or replace function add_working_days(p_from date, p_n int) returns date
language plpgsql stable as $$
declare d date := p_from; step int := case when p_n < 0 then -1 else 1 end; left_n int := abs(p_n);
begin
  while left_n > 0 loop
    d := d + step;
    if extract(isodow from d) < 6 and not exists (select 1 from holidays where day = d) then
      left_n := left_n - 1;
    end if;
  end loop;
  return d;
end $$;

-- Event-based: Due date = event date + N days. Logs the event and creates the obligation.
create or replace function create_event_obligation(p_client uuid, p_rule_key text, p_event_date date, p_note text default null)
returns uuid language plpgsql security invoker set search_path = public as $$
declare c clients; rv rule_versions; ev uuid; due date; ob uuid; sch jsonb; n int; wd boolean;
begin
  select * into c from clients where id = p_client;                 -- RLS applies
  if not found then raise exception 'client not found or not accessible'; end if;
  select v.* into rv from rule_versions v join rules r on r.id = v.rule_id
   where r.rule_key = p_rule_key and v.state = 'active';
  if not found then raise exception 'no active rule %', p_rule_key; end if;
  if rv.kind <> 'event' then raise exception 'rule % is not event-based', p_rule_key; end if;
  sch := rv.schedule;
  n   := coalesce((sch->>'days')::int, 0) * coalesce((sch->>'direction')::int, 1);
  wd  := coalesce(sch->>'day_type','calendar') = 'working';
  due := case when wd then add_working_days(p_event_date, n) else p_event_date + n end;

  insert into events(org_id, client_id, trigger_event, event_date, note, created_by)
  values (c.org_id, c.id, coalesce(rv.trigger_event, p_rule_key), p_event_date, p_note, auth.uid())
  returning id into ev;

  insert into obligations(org_id, client_id, rule_version_id, event_id, period_label, due_date, due_date_basis)
  values (c.org_id, c.id, rv.id, ev, to_char(p_event_date,'YYYY-MM-DD'), due,
          format('%s %s + %s %s days', coalesce(rv.trigger_event,'event'), p_event_date, abs(n), case when wd then 'working' else 'calendar' end))
  returning id into ob;
  return ob;
end $$;

-- Fixed-calendar: generate obligations for one client between two dates (idempotent).
create or replace function generate_fixed_obligations(p_client uuid, p_from date, p_to date)
returns int language plpgsql security invoker set search_path = public as $$
declare c clients; rv record; s jsonb; t text; m date; y int; md text; d date; made int := 0; cnt int;
begin
  select * into c from clients where id = p_client;
  if not found then raise exception 'client not found or not accessible'; end if;

  for rv in
    select v.* from rule_versions v
     where v.state = 'active' and v.kind in ('fixed','recurring')
       and c.profile @> v.applies_when
       and (v.effective_from is null or v.effective_from <= p_to)
       and (v.effective_until is null or v.effective_until >= p_from)
  loop
    s := rv.schedule; t := s->>'type';

    if t = 'monthly' then
      -- obligation for month M is due on `day` of month M+1
      for m in select generate_series(date_trunc('month', p_from) - interval '1 month', date_trunc('month', p_to), interval '1 month')::date loop
        d := (m + interval '1 month')::date + ((s->>'day')::int - 1);
        if d between p_from and p_to then
          insert into obligations(org_id, client_id, rule_version_id, period_label, due_date, due_date_basis)
          values (c.org_id, c.id, rv.id, to_char(m,'Mon YYYY'), d, format('%sth of month after period', s->>'day'))
          on conflict do nothing;
          get diagnostics cnt = row_count; made := made + cnt;
        end if;
      end loop;

    elsif t = 'annual' then
      for y in extract(year from p_from)::int .. extract(year from p_to)::int loop
        d := make_date(y, (s->>'month')::int, (s->>'day')::int);
        if d between p_from and p_to then
          insert into obligations(org_id, client_id, rule_version_id, period_label, due_date, due_date_basis)
          values (c.org_id, c.id, rv.id, 'Due '||to_char(d,'DD Mon YYYY'), d, 'fixed annual date')
          on conflict do nothing;
          get diagnostics cnt = row_count; made := made + cnt;
        end if;
      end loop;

    elsif t = 'dates' then
      for y in extract(year from p_from)::int .. extract(year from p_to)::int loop
        for md in select jsonb_array_elements_text(s->'dates') loop
          d := make_date(y, split_part(md,'-',1)::int, split_part(md,'-',2)::int);
          if d between p_from and p_to then
            insert into obligations(org_id, client_id, rule_version_id, period_label, due_date, due_date_basis)
            values (c.org_id, c.id, rv.id, 'Due '||to_char(d,'DD Mon YYYY'), d, 'fixed date list')
            on conflict do nothing;
            get diagnostics cnt = row_count; made := made + cnt;
          end if;
        end loop;
      end loop;

    elsif t = 'after_period' and s->>'unit' = 'quarter' then
      -- calendar quarters (Jan-Mar, Apr-Jun, ...); due = quarter end + N days
      for m in select generate_series(date_trunc('quarter', p_from) - interval '3 months', date_trunc('quarter', p_to), interval '3 months')::date loop
        d := (m + interval '3 months')::date - 1 + (s->>'days')::int;
        if d between p_from and p_to then
          insert into obligations(org_id, client_id, rule_version_id, period_label, due_date, due_date_basis)
          values (c.org_id, c.id, rv.id, 'Qtr ending '||to_char((m + interval '3 months')::date - 1,'DD Mon YYYY'), d,
                  format('quarter end + %s days', s->>'days'))
          on conflict do nothing;
          get diagnostics cnt = row_count; made := made + cnt;
        end if;
      end loop;
    end if;
    -- other shapes (event, varies) are skipped by design
  end loop;
  return made;
end $$;

-- Publish an approved queue item as a new active rule version (admin/service role only).
create or replace function approve_rule_change(p_queue uuid, p_reviewer uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare q rule_review_queue; r uuid; nv int; new_id uuid; p jsonb;
begin
  select * into q from rule_review_queue where id = p_queue and state = 'pending' for update;
  if not found then raise exception 'queue item not pending'; end if;
  p := q.proposed;
  r := q.rule_id;
  if r is null then
    insert into rules(rule_key, law, form, title)
    values (p->>'rule_key', (p->>'law')::law_code, p->>'form', p->>'title') returning id into r;
  end if;
  select coalesce(max(version),0)+1 into nv from rule_versions where rule_id = r;
  update rule_versions set state = 'superseded', effective_until = coalesce(effective_until, q.effective_date)
   where rule_id = r and state = 'active';
  insert into rule_versions(rule_id, version, state, kind, section_or_rule, authority, applicability_text, applies_when,
        frequency, trigger_event, schedule, due_text, due_basis, due_calculation, penalty, source_url, source_document,
        source_date, effective_from, last_checked, confidence, notes, approved_by, approved_at)
  values (r, nv, 'active', (p->>'kind')::rule_kind, p->>'section_or_rule', p->>'authority', p->>'applicability_text',
        coalesce(p->'applies_when','{}'::jsonb), p->>'frequency', p->>'trigger_event', p->'schedule', p->>'due_text',
        p->>'due_basis', p->>'due_calculation', p->>'penalty', p->>'source_url', p->>'source_document',
        nullif(p->>'source_date','')::date, coalesce(q.effective_date, current_date), current_date,
        coalesce((p->>'confidence')::confidence,'low'), p->>'notes', p_reviewer, now())
  returning id into new_id;
  update rule_review_queue set state='approved', reviewed_by=p_reviewer, reviewed_at=now() where id = p_queue;
  insert into audit_log(user_id, action, entity, entity_id, detail) values (p_reviewer,'approve','rule_version',new_id,jsonb_build_object('queue',p_queue));
  return new_id;
end $$;
revoke all on function approve_rule_change(uuid, uuid) from public, anon, authenticated;

-- ───────────── row level security ─────────────
alter table orgs                enable row level security;
alter table org_members         enable row level security;
alter table clients             enable row level security;
alter table rules               enable row level security;
alter table rule_versions       enable row level security;
alter table rule_sources        enable row level security;
alter table rule_review_queue   enable row level security;
alter table holidays            enable row level security;
alter table events              enable row level security;
alter table obligations         enable row level security;
alter table documents           enable row level security;
alter table notifications       enable row level security;
alter table audit_log           enable row level security;

-- orgs / membership
create policy orgs_select on orgs for select using (is_org_member(id));
create policy orgs_update on orgs for update using (is_org_admin(id)) with check (is_org_admin(id));
create policy members_select on org_members for select using (is_org_member(org_id));
create policy members_admin  on org_members for all using (is_org_admin(org_id)) with check (is_org_admin(org_id));

-- tenant data: readable by members, writable by owner/admin/member roles
create policy clients_select on clients for select using (is_org_member(org_id));
create policy clients_write  on clients for all    using (can_write_org(org_id)) with check (can_write_org(org_id));
create policy events_select  on events  for select using (is_org_member(org_id));
create policy events_write   on events  for all    using (can_write_org(org_id)) with check (can_write_org(org_id));
create policy obl_select     on obligations for select using (is_org_member(org_id));
create policy obl_write      on obligations for all    using (can_write_org(org_id)) with check (can_write_org(org_id));
create policy docs_select    on documents for select using (is_org_member(org_id));
create policy docs_write     on documents for all    using (can_write_org(org_id)) with check (can_write_org(org_id));
create policy notif_select   on notifications for select using (is_org_member(org_id));
create policy audit_select   on audit_log for select using (org_id is not null and is_org_admin(org_id));

-- global rulebook: any signed-in user may read active content; no tenant writes
create policy rules_read     on rules         for select to authenticated using (true);
create policy rv_read        on rule_versions for select to authenticated using (state in ('active','superseded','repealed'));
create policy rsrc_read      on rule_sources  for select to authenticated using (
  exists (select 1 from rule_versions v where v.id = rule_version_id and v.state in ('active','superseded','repealed')));
create policy holidays_read  on holidays      for select to authenticated using (true);
-- rule_review_queue: no policy = service role only

-- creating an org makes the creator its owner
create or replace function create_org(p_name text, p_type org_type) returns uuid
language plpgsql security definer set search_path = public as $$
declare o uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into orgs(name, type) values (p_name, p_type) returning id into o;
  insert into org_members(org_id, user_id, role) values (o, auth.uid(), 'owner');
  return o;
end $$;
grant execute on function create_org(text, org_type) to authenticated;

-- ═══════════════ PART 2 ═══════════════

-- REGULENTA AI — migration 002 (runs after 001_complytrack_schema.sql)
-- Adds: platform roles, authorities/sources/monitoring, regulatory documents + evidence, change detection,
-- the research queue with a hard "AI cannot activate a rule" guard, due-date history, reminders,
-- in-app notifications, settings, freshness, applicability explainer and storage policies.

-- ───────────── platform roles (staff who run the rulebook) ─────────────
-- Client-side roles stay on org_members: owner/admin = firm or company admin,
-- member = compliance manager, viewer = client (read-only).
create type platform_role as enum ('super_admin','admin','reviewer');

create table platform_roles (
  user_id uuid not null references auth.users(id) on delete cascade,
  role platform_role not null,
  created_at timestamptz not null default now(),
  primary key (user_id, role)
);

create or replace function has_platform_role(p_roles platform_role[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from platform_roles where user_id = auth.uid() and role = any(p_roles))
$$;
create or replace function is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from platform_roles where user_id = auth.uid())
$$;

-- ───────────── settings ─────────────
create table system_settings (
  key text primary key,
  value jsonb not null,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);
insert into system_settings(key, value) values
 ('product_name',  '"REGULENTA AI"'),
 ('tagline',       '"AI Regulatory & Compliance Intelligence Platform"'),
 ('disclaimer',    '"Regulatory intelligence and compliance-management assistance. Final legal, tax, secretarial, accounting or regulatory interpretation should be independently reviewed by the appropriate professional."'),
 ('stale_after_days', '90'),
 ('default_reminder_offsets', '[30,15,7,3,1,0]');

-- ───────────── authorities and sources ─────────────
create type jurisdiction_level as enum ('central','state','local');
create type source_type as enum ('webpage','notification_page','circular_repository','pdf','gazette','document','announcement','rss','api');
create type source_status as enum ('active','disabled','failing','needs_verification');

create table regulatory_authorities (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,                    -- 'MCA','SEBI','RBI', 'HR-LABOUR'
  name text not null,
  level jurisdiction_level not null default 'central',
  jurisdiction text,                            -- 'India', 'Haryana', ...
  parent_id uuid references regulatory_authorities(id),
  website text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table regulatory_sources (
  id uuid primary key default gen_random_uuid(),
  authority_id uuid not null references regulatory_authorities(id) on delete cascade,
  name text not null,
  url text not null,
  source_type source_type not null,
  priority smallint not null default 3 check (priority between 1 and 5),   -- 1 = most critical
  check_every_hours int not null default 24 check (check_every_hours >= 1),
  status source_status not null default 'needs_verification',
  last_checked_at timestamptz,
  last_success_at timestamptz,
  last_change_at timestamptz,
  next_check_at timestamptz,
  last_http_status int,
  consecutive_failures int not null default 0,
  last_content_hash text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (authority_id, url)
);
create index on regulatory_sources (next_check_at) where status in ('active','failing');

create table monitoring_jobs (
  id uuid primary key default gen_random_uuid(),
  source_id uuid not null references regulatory_sources(id) on delete cascade,
  trigger text not null default 'scheduled' check (trigger in ('scheduled','manual','retry')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'running' check (status in ('running','success','failed')),
  http_status int,
  error text,
  content_hash text,
  change_detected boolean not null default false,
  retry_of uuid references monitoring_jobs(id)
);
create index on monitoring_jobs (source_id, started_at desc);

-- Record a finished check. A failed check never touches rules; it only flags the source.
create or replace function record_source_check(p_source uuid, p_ok boolean, p_http int, p_hash text, p_error text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare s regulatory_sources; changed boolean; j uuid;
begin
  select * into s from regulatory_sources where id = p_source for update;
  if not found then raise exception 'source not found'; end if;
  changed := p_ok and p_hash is not null and p_hash is distinct from s.last_content_hash and s.last_content_hash is not null;
  insert into monitoring_jobs(source_id, finished_at, status, http_status, error, content_hash, change_detected)
  values (p_source, now(), case when p_ok then 'success' else 'failed' end, p_http, p_error, p_hash, changed)
  returning id into j;
  if p_ok then
    update regulatory_sources set last_checked_at = now(), last_success_at = now(), last_http_status = p_http,
           consecutive_failures = 0, last_content_hash = p_hash,
           last_change_at = case when changed then now() else last_change_at end,
           status = case when status in ('failing','needs_verification') then 'active' else status end,
           next_check_at = now() + make_interval(hours => check_every_hours)
     where id = p_source;
  else
    update regulatory_sources set last_checked_at = now(), last_http_status = p_http,
           consecutive_failures = consecutive_failures + 1, status = 'failing',
           -- exponential back-off, capped at the normal interval
           next_check_at = now() + least(make_interval(hours => check_every_hours), make_interval(mins => 15 * power(2, least(consecutive_failures, 6))::int))
     where id = p_source;
  end if;
  return j;
end $$;
revoke all on function record_source_check(uuid,boolean,int,text,text) from public, anon, authenticated;

-- ───────────── regulatory documents (evidence store) ─────────────
create type doc_status as enum ('current','superseded','withdrawn','unverified');

create table regulatory_documents (
  id uuid primary key default gen_random_uuid(),
  authority_id uuid not null references regulatory_authorities(id),
  source_id uuid references regulatory_sources(id) on delete set null,
  title text not null,
  doc_type text not null,                      -- 'notification','circular','order','gazette','act','rules','regulations','faq','judgment'
  doc_number text,                             -- notification / circular number as printed
  official_url text not null,
  published_on date,
  effective_on date,
  doc_date date,
  storage_path text,                           -- object in bucket 'regulatory-docs'
  sha256 text,
  extracted_text text,
  ai_summary text,
  relevant_provisions text,
  status doc_status not null default 'unverified',
  supersedes_id uuid references regulatory_documents(id),
  superseded_by_id uuid references regulatory_documents(id),
  fetched_at timestamptz not null default now(),
  last_verified_at timestamptz,
  verified_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (authority_id, sha256)
);
create index on regulatory_documents (authority_id, published_on desc);
create index regdoc_text_fts on regulatory_documents using gin (to_tsvector('english', coalesce(title,'') || ' ' || coalesce(extracted_text,'')));

-- exact supporting passage for a rule version (what "View Evidence" shows)
create table rule_evidence (
  id uuid primary key default gen_random_uuid(),
  rule_version_id uuid not null references rule_versions(id) on delete cascade,
  document_id uuid not null references regulatory_documents(id),
  evidence_type text not null default 'primary' check (evidence_type in ('primary','clarification','judicial','cross_check')),
  act text, regulation text, rule text, section text,
  notification_no text, circular_no text,
  passage text not null,
  page_number int,
  verified_by uuid references auth.users(id),
  verified_at timestamptz,
  created_at timestamptz not null default now()
);
create index on rule_evidence (rule_version_id);
create index on rule_evidence (document_id);

-- ───────────── rule_versions additions ─────────────
alter table rule_versions
  add column next_review_at date,
  add column ai_originated boolean not null default false,
  add column human_verified_by uuid references auth.users(id),
  add column human_verified_at timestamptz,
  add column show_warning boolean generated always as (confidence <> 'high') stored;

-- A rule can only be active if a human approved it ...
alter table rule_versions add constraint active_requires_approval
  check (state <> 'active' or (approved_by is not null and approved_at is not null));

-- ... and only through approve_rule_change(): direct writes of state='active' are refused for everyone,
-- including the service role (which the AI engine uses).
create or replace function guard_active_rule() returns trigger language plpgsql as $$
begin
  if new.state = 'active'
     and (tg_op = 'INSERT' or old.state is distinct from 'active')
     and coalesce(current_setting('regulenta.approving', true), '') <> 'on' then
    raise exception 'rule versions can only be activated through approve_rule_change()' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger t_guard_active before insert or update on rule_versions
  for each row execute function guard_active_rule();

-- stale rules
create or replace view stale_rules with (security_invoker = true) as
select r.rule_key, r.form, r.title, v.id as rule_version_id, v.last_checked, v.next_review_at,
       'STALE — VERIFICATION REQUIRED' as flag
  from rule_versions v join rules r on r.id = v.rule_id
 where v.state = 'active'
   and (v.last_checked is null
        or v.last_checked < current_date - coalesce((select (value #>> '{}')::int from system_settings where key = 'stale_after_days'), 90)
        or v.next_review_at < current_date);

-- ───────────── change detection + research queue ─────────────
create type change_type as enum ('new_notification','new_circular','new_order','new_regulation','new_rule','amendment','repeal','replacement',
  'extension','due_date_extension','new_form','revised_form','new_filing_requirement','changed_threshold','changed_applicability',
  'changed_penalty','changed_frequency','changed_reporting','new_exemption','withdrawal','clarification','judicial','interpretation');
create type research_status as enum ('new','ai_researched','pending_review','approved','rejected','needs_more_research','superseded','conflict');

create table regulatory_changes (
  id uuid primary key default gen_random_uuid(),
  authority_id uuid not null references regulatory_authorities(id),
  source_id uuid references regulatory_sources(id) on delete set null,
  document_id uuid references regulatory_documents(id) on delete set null,
  change_type change_type not null,
  affected_law text,
  affected_provision text,
  published_on date,
  effective_on date,
  previous_requirement text,
  new_requirement text,
  status research_status not null default 'new',
  detected_at timestamptz not null default now()
);
create index on regulatory_changes (status, detected_at desc);

-- replaces v1 rule_review_queue (empty, never applied)
drop function if exists approve_rule_change(uuid, uuid);
drop table if exists rule_review_queue;

create table research_queue (
  id uuid primary key default gen_random_uuid(),
  change_id uuid references regulatory_changes(id) on delete set null,
  rule_id uuid references rules(id) on delete set null,          -- null = proposed new rule
  authority_id uuid references regulatory_authorities(id),
  document_id uuid references regulatory_documents(id),
  change_type change_type,
  ai_summary text,
  ai_extracted_requirement text,
  previous_rule text,
  proposed jsonb not null,                                       -- full proposed rule_versions content
  proposed_applicability text,
  proposed_due_date text,
  proposed_penalty text,
  evidence jsonb not null default '[]'::jsonb,                   -- [{document_id, passage, page}]
  confidence confidence not null default 'low',
  conflict_note text,
  effective_date date,
  status research_status not null default 'pending_review',
  researched_at timestamptz not null default now(),
  reviewer uuid references auth.users(id),
  reviewer_comments text,
  approved_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now()
);
create index on research_queue (status);

-- Approval: reviewer/admin only. Creates a new version, preserves the old one, writes evidence, audits,
-- recalculates affected obligations and notifies affected clients. Nothing else can activate a rule.
create or replace function approve_rule_change(p_queue uuid, p_comments text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare q research_queue; r uuid; nv int; new_id uuid; p jsonb; ev jsonb; old_id uuid; n_recalc int;
begin
  if not has_platform_role(array['reviewer','admin','super_admin']::platform_role[]) then
    raise exception 'only reviewers or admins may approve rule changes' using errcode = '42501';
  end if;
  select * into q from research_queue where id = p_queue and status in ('pending_review','ai_researched','conflict') for update;
  if not found then raise exception 'queue item is not awaiting review'; end if;
  if q.status = 'conflict' then raise exception 'conflicting sources must be resolved first'; end if;
  p := q.proposed;
  if jsonb_array_length(q.evidence) = 0 then raise exception 'cannot approve without evidence (RESEARCH REQUIRED)'; end if;

  perform set_config('regulenta.approving', 'on', true);

  r := q.rule_id;
  if r is null then
    insert into rules(rule_key, law, form, title)
    values (p->>'rule_key', (p->>'law')::law_code, p->>'form', p->>'title') returning id into r;
  end if;
  select id into old_id from rule_versions where rule_id = r and state = 'active';
  select coalesce(max(version),0)+1 into nv from rule_versions where rule_id = r;
  if old_id is not null then
    update rule_versions set state = 'superseded', effective_until = coalesce(q.effective_date, current_date) where id = old_id;
  end if;

  insert into rule_versions(rule_id, version, state, kind, section_or_rule, authority, applicability_text, applies_when,
        frequency, trigger_event, schedule, due_text, due_basis, due_calculation, penalty, source_url, source_document,
        source_date, effective_from, last_checked, next_review_at, confidence, notes, ai_originated,
        approved_by, approved_at, human_verified_by, human_verified_at)
  values (r, nv,
        case when coalesce(q.effective_date, current_date) > current_date then 'not_yet_effective' else 'active' end::rule_state,
        (p->>'kind')::rule_kind, p->>'section_or_rule', p->>'authority', p->>'applicability_text',
        coalesce(p->'applies_when','{}'::jsonb), p->>'frequency', p->>'trigger_event', p->'schedule', p->>'due_text',
        p->>'due_basis', p->>'due_calculation', p->>'penalty', p->>'source_url', p->>'source_document',
        nullif(p->>'source_date','')::date, coalesce(q.effective_date, current_date), current_date,
        current_date + coalesce((select (value #>> '{}')::int from system_settings where key='stale_after_days'),90),
        q.confidence, p->>'notes', true, auth.uid(), now(), auth.uid(), now())
  returning id into new_id;

  for ev in select * from jsonb_array_elements(q.evidence) loop
    insert into rule_evidence(rule_version_id, document_id, passage, page_number, verified_by, verified_at)
    values (new_id, (ev->>'document_id')::uuid, ev->>'passage', nullif(ev->>'page','')::int, auth.uid(), now());
  end loop;

  update research_queue set status = 'approved', reviewer = auth.uid(), reviewer_comments = p_comments, approved_at = now() where id = p_queue;
  if old_id is not null then
    update research_queue set status = 'superseded' where rule_id = r and status in ('pending_review','ai_researched') and id <> p_queue;
  end if;
  if q.change_id is not null then update regulatory_changes set status = 'approved' where id = q.change_id; end if;
  insert into audit_log(user_id, action, entity, entity_id, detail)
  values (auth.uid(), 'approve', 'rule_version', new_id, jsonb_build_object('queue', p_queue, 'previous_version', old_id, 'confidence', q.confidence));

  n_recalc := recalc_after_rule_change(new_id, old_id);
  return new_id;
end $$;
grant execute on function approve_rule_change(uuid, text) to authenticated;

create or replace function reject_rule_change(p_queue uuid, p_reason text, p_needs_more boolean default false)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not has_platform_role(array['reviewer','admin','super_admin']::platform_role[]) then
    raise exception 'only reviewers or admins may review changes' using errcode = '42501';
  end if;
  update research_queue
     set status = case when p_needs_more then 'needs_more_research' else 'rejected' end::research_status,
         reviewer = auth.uid(), reviewer_comments = p_reason, rejection_reason = case when p_needs_more then null else p_reason end,
         approved_at = null
   where id = p_queue and status in ('pending_review','ai_researched','conflict');
  if not found then raise exception 'queue item is not awaiting review'; end if;
  insert into audit_log(user_id, action, entity, entity_id, detail)
  values (auth.uid(), case when p_needs_more then 'needs_more_research' else 'reject' end, 'research_queue', p_queue, jsonb_build_object('reason', p_reason));
end $$;
grant execute on function reject_rule_change(uuid, text, boolean) to authenticated;

-- ───────────── due dates: history + extensions ─────────────
alter table obligations add column original_due_date date;
update obligations set original_due_date = due_date where original_due_date is null;
create or replace function set_original_due() returns trigger language plpgsql as $$
begin if new.original_due_date is null then new.original_due_date := new.due_date; end if; return new; end $$;
create trigger t_orig_due before insert on obligations for each row execute function set_original_due();

create type calc_kind as enum ('initial','extension','recalculation','manual');
create table due_date_calculations (
  id uuid primary key default gen_random_uuid(),
  obligation_id uuid not null references obligations(id) on delete cascade,
  kind calc_kind not null,
  due_date date not null,
  previous_due_date date,
  explanation text not null,                 -- "why this date was calculated"
  rule_version_id uuid references rule_versions(id),
  change_id uuid references regulatory_changes(id),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index on due_date_calculations (obligation_id, created_at);

-- log every initial calculation automatically
create or replace function log_initial_due() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into due_date_calculations(obligation_id, kind, due_date, explanation, rule_version_id, created_by)
  values (new.id, 'initial', new.due_date, coalesce(new.due_date_basis, 'calculated from rule'), new.rule_version_id, auth.uid());
  return new;
end $$;
create trigger t_log_initial after insert on obligations for each row execute function log_initial_due();

-- Extension granted by an authority: keeps original_due_date, records revised date and reason.
create or replace function extend_obligation(p_obligation uuid, p_new_date date, p_reason text, p_change uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare o obligations;
begin
  select * into o from obligations where id = p_obligation;
  if not found or not can_write_org(o.org_id) then raise exception 'obligation not found or not accessible'; end if;
  update obligations set due_date = p_new_date where id = p_obligation;
  insert into due_date_calculations(obligation_id, kind, due_date, previous_due_date, explanation, change_id, created_by)
  values (p_obligation, 'extension', p_new_date, o.due_date, p_reason, p_change, auth.uid());
end $$;
revoke all on function extend_obligation(uuid,date,text,uuid) from public, anon;
grant execute on function extend_obligation(uuid,date,text,uuid) to authenticated;

-- ───────────── reminders + in-app notifications ─────────────
-- v1 "notifications" held scheduled sends; it becomes "reminders". "notifications" is now the in-app feed.
alter table notifications rename to reminders;
alter table reminders
  add column kind text not null default 'upcoming' check (kind in ('upcoming','due_today','overdue')),
  add column offset_days int,
  add column last_error text;

create table reminder_settings (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs(id) on delete cascade,
  client_id uuid references clients(id) on delete cascade,        -- null = org default
  offsets int[] not null default '{30,15,7,3,1,0}',
  channels text[] not null default '{in_app,email}'
);
create unique index reminder_settings_org_default on reminder_settings (org_id) where client_id is null;
create unique index reminder_settings_client on reminder_settings (org_id, client_id) where client_id is not null;

create type notif_category as enum ('compliance_reminder','regulatory_update','amendment','new_compliance','due_date_change','overdue','review_required','source_verification','system_alert');
create table notifications (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references orgs(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,        -- null = everyone in the org; staff items use org_id null
  category notif_category not null,
  title text not null,
  body text,
  client_id uuid references clients(id) on delete cascade,
  obligation_id uuid references obligations(id) on delete cascade,
  rule_id uuid references rules(id) on delete set null,
  source_id uuid references regulatory_sources(id) on delete set null,
  document_id uuid references regulatory_documents(id) on delete set null,
  change_id uuid references regulatory_changes(id) on delete set null,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index on notifications (org_id, created_at desc);
create index on notifications (user_id, read_at);

-- (Re)build the reminder schedule for one obligation. Future dates only; unsent rows are replaced.
create or replace function schedule_reminders(p_obligation uuid) returns int
language plpgsql security definer set search_path = public as $$
declare o obligations; offs int[]; n int; d date; made int := 0; ch text; chans text[];
begin
  select * into o from obligations where id = p_obligation;
  if not found or o.status in ('filed','not_applicable','waived') then return 0; end if;
  select coalesce(
           (select offsets from reminder_settings where org_id = o.org_id and client_id = o.client_id),
           (select offsets from reminder_settings where org_id = o.org_id and client_id is null),
           array(select jsonb_array_elements_text((select value from system_settings where key='default_reminder_offsets'))::int)),
         coalesce(
           (select channels from reminder_settings where org_id = o.org_id and client_id = o.client_id),
           (select channels from reminder_settings where org_id = o.org_id and client_id is null),
           '{in_app,email}')
    into offs, chans;
  delete from reminders where obligation_id = p_obligation and sent_at is null;
  foreach n in array offs loop
    d := o.due_date - n;
    if d >= current_date then
      foreach ch in array chans loop
        insert into reminders(org_id, obligation_id, channel, send_on, kind, offset_days)
        values (o.org_id, o.id, ch, d, case when n = 0 then 'due_today' else 'upcoming' end, n)
        on conflict do nothing;
        made := made + 1;
      end loop;
    end if;
  end loop;
  return made;
end $$;
revoke all on function schedule_reminders(uuid) from public, anon, authenticated;

create or replace function trg_reschedule() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or old.due_date is distinct from new.due_date or old.status is distinct from new.status then
    perform schedule_reminders(new.id);
  end if;
  return null;
end $$;
create trigger t_obl_reminders after insert or update on obligations for each row execute function trg_reschedule();

-- Daily job (run by pg_cron or an Edge Function): turn due reminders into in-app notifications,
-- and raise overdue notices once per day.
create or replace function run_daily_reminders(p_today date default current_date) returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; c int;
begin
  insert into notifications(org_id, category, title, body, client_id, obligation_id)
  select r.org_id, 'compliance_reminder',
         case r.kind when 'due_today' then 'Compliance is due today' else format('Compliance due in %s days', r.offset_days) end,
         format('%s — due %s', ru.form, o.due_date), o.client_id, o.id
    from reminders r join obligations o on o.id = r.obligation_id
    join rule_versions v on v.id = o.rule_version_id join rules ru on ru.id = v.rule_id
   where r.send_on = p_today and r.sent_at is null and r.channel = 'in_app' and o.status not in ('filed','not_applicable','waived');
  get diagnostics c = row_count; n := n + c;
  update reminders set sent_at = now() where send_on = p_today and sent_at is null and channel = 'in_app';

  insert into notifications(org_id, category, title, body, client_id, obligation_id)
  select o.org_id, 'overdue', 'Compliance is overdue', format('%s was due %s', ru.form, o.due_date), o.client_id, o.id
    from obligations o join rule_versions v on v.id = o.rule_version_id join rules ru on ru.id = v.rule_id
   where o.due_date < p_today and o.status in ('upcoming','in_progress')
     and not exists (select 1 from notifications x where x.obligation_id = o.id and x.category = 'overdue' and x.created_at::date = p_today);
  get diagnostics c = row_count; n := n + c;
  return n;
end $$;
revoke all on function run_daily_reminders(date) from public, anon, authenticated;

-- ───────────── applicability engine ─────────────
-- applies_when shapes: {"listed":true}  (equality) | {"employees":{"gte":20}} | {"state":{"in":["Haryana","Delhi"]}}
-- Missing profile fact => REVIEW_REQUIRED (never silently assumed).
create or replace function evaluate_applicability(p_client uuid, p_rule_version uuid)
returns table(result text, reasons jsonb) language plpgsql stable security invoker set search_path = public as $$
declare c clients; v rule_versions; k text; cond jsonb; have jsonb; ok boolean; msgs jsonb := '[]'::jsonb;
        res text := 'applicable'; op text; val jsonb;
begin
  select * into c from clients where id = p_client;
  select * into v from rule_versions where id = p_rule_version;
  if c.id is null or v.id is null then raise exception 'not found or not accessible'; end if;
  if v.state <> 'active' then
    return query select 'review_required', jsonb_build_array('rule version is ' || v.state::text || ', not active'); return;
  end if;
  for k, cond in select * from jsonb_each(v.applies_when) loop
    have := c.profile -> k;
    if have is null then
      res := case when res = 'not_applicable' then res else 'review_required' end;
      msgs := msgs || to_jsonb(format('Review required: profile has no value for "%s" (rule needs %s)', k, cond));
      continue;
    end if;
    if jsonb_typeof(cond) = 'object' then
      ok := true;
      for op, val in select * from jsonb_each(cond) loop
        ok := ok and case op
          when 'gte' then (have #>> '{}')::numeric >= (val #>> '{}')::numeric
          when 'gt'  then (have #>> '{}')::numeric >  (val #>> '{}')::numeric
          when 'lte' then (have #>> '{}')::numeric <= (val #>> '{}')::numeric
          when 'lt'  then (have #>> '{}')::numeric <  (val #>> '{}')::numeric
          when 'in'  then val @> jsonb_build_array(have)
          else false end;
      end loop;
    else
      ok := have = cond;
    end if;
    if ok then msgs := msgs || to_jsonb(format('Applicable because %s = %s meets condition %s', k, have, cond));
    else res := 'not_applicable'; msgs := msgs || to_jsonb(format('Not applicable because %s = %s does not meet condition %s', k, have, cond)); end if;
  end loop;
  if jsonb_array_length(msgs) = 0 then msgs := to_jsonb(array['Applies to all entities (no conditions on this rule)']); end if;
  return query select res, msgs;
end $$;

-- ───────────── impact analysis + recalculation after approval ─────────────
create or replace function recalc_after_rule_change(p_new uuid, p_old uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; o record; nv rule_versions; nd date; ev int; rid uuid;
begin
  select * into nv from rule_versions where id = p_new;
  select rule_id into rid from rule_versions where id = p_new;
  if nv.state <> 'active' or p_old is null then return 0; end if;
  -- open obligations pointing at the superseded version move to the new version; event-based ones are recomputed
  for o in select ob.*, e.event_date from obligations ob left join events e on e.id = ob.event_id
            where ob.rule_version_id = p_old and ob.status in ('upcoming','in_progress') loop
    nd := o.due_date;
    if nv.kind = 'event' and o.event_date is not null then
      nd := case when coalesce(nv.schedule->>'day_type','calendar') = 'working'
                 then add_working_days(o.event_date, coalesce((nv.schedule->>'days')::int,0) * coalesce((nv.schedule->>'direction')::int,1))
                 else o.event_date + coalesce((nv.schedule->>'days')::int,0) * coalesce((nv.schedule->>'direction')::int,1) end;
    end if;
    update obligations set rule_version_id = p_new, due_date = nd where id = o.id;
    insert into due_date_calculations(obligation_id, kind, due_date, previous_due_date, explanation, rule_version_id)
    values (o.id, 'recalculation', nd, o.due_date, 'Recalculated after rule amendment (new version approved)', p_new);
    insert into notifications(org_id, category, title, body, client_id, obligation_id, rule_id)
    values (o.org_id, case when nd is distinct from o.due_date then 'due_date_change' else 'amendment' end::notif_category,
            case when nd is distinct from o.due_date then 'Deadline has changed' else 'This compliance requirement has been amended' end,
            format('Due date %s → %s', o.due_date, nd), o.client_id, o.id, rid);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function recalc_after_rule_change(uuid, uuid) from public, anon, authenticated;

-- Impact report: which clients/obligations a rule touches (used before approval and in the review screen)
create or replace function rule_impact(p_rule uuid)
returns table(org_id uuid, client_id uuid, client_name text, open_obligations bigint)
language sql stable security definer set search_path = public as $$
  select c.org_id, c.id, c.name, count(o.id)
    from obligations o join rule_versions v on v.id = o.rule_version_id join clients c on c.id = o.client_id
   where v.rule_id = p_rule and o.status in ('upcoming','in_progress')
     and has_platform_role(array['reviewer','admin','super_admin']::platform_role[])
   group by c.org_id, c.id, c.name
$$;
revoke all on function rule_impact(uuid) from public, anon;
grant execute on function rule_impact(uuid) to authenticated;

-- ───────────── audit triggers for rulebook tables ─────────────
create or replace function audit_generic() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log(user_id, action, entity, entity_id, detail)
  values (auth.uid(), lower(tg_op), tg_table_name, coalesce(new.id, old.id),
          jsonb_build_object('old', case when tg_op <> 'INSERT' then to_jsonb(old) end, 'new', case when tg_op <> 'DELETE' then to_jsonb(new) end));
  return coalesce(new, old);
end $$;
create trigger t_audit_sources before insert or update or delete on regulatory_sources for each row execute function audit_generic();
create trigger t_audit_docs    before insert or update or delete on regulatory_documents for each row execute function audit_generic();
create trigger t_audit_settings before update on system_settings for each row execute function audit_generic();
-- system_settings has no id column; give audit a stable key instead
alter table system_settings add column id uuid not null default gen_random_uuid();

-- updated_at
create trigger t_auth_upd before update on regulatory_authorities for each row execute function set_updated_at();
create trigger t_src_upd  before update on regulatory_sources for each row execute function set_updated_at();

-- ───────────── row level security ─────────────
alter table platform_roles          enable row level security;
alter table system_settings         enable row level security;
alter table regulatory_authorities  enable row level security;
alter table regulatory_sources      enable row level security;
alter table monitoring_jobs         enable row level security;
alter table regulatory_documents    enable row level security;
alter table rule_evidence           enable row level security;
alter table regulatory_changes      enable row level security;
alter table research_queue          enable row level security;
alter table due_date_calculations   enable row level security;
alter table reminders               enable row level security;
alter table reminder_settings       enable row level security;
alter table notifications           enable row level security;

create policy pr_self   on platform_roles for select using (user_id = auth.uid() or has_platform_role(array['super_admin']::platform_role[]));
create policy pr_super  on platform_roles for all using (has_platform_role(array['super_admin']::platform_role[])) with check (has_platform_role(array['super_admin']::platform_role[]));

create policy set_read  on system_settings for select to authenticated using (true);
create policy set_write on system_settings for update using (has_platform_role(array['super_admin']::platform_role[])) with check (has_platform_role(array['super_admin']::platform_role[]));

create policy auth_read  on regulatory_authorities for select to authenticated using (true);
create policy auth_write on regulatory_authorities for all using (has_platform_role(array['super_admin','admin']::platform_role[])) with check (has_platform_role(array['super_admin','admin']::platform_role[]));

-- sources, jobs, queue: staff only (clients never see raw monitoring)
create policy src_staff on regulatory_sources for select using (is_staff());
create policy src_admin on regulatory_sources for all using (has_platform_role(array['super_admin','admin']::platform_role[])) with check (has_platform_role(array['super_admin','admin']::platform_role[]));
create policy job_staff on monitoring_jobs for select using (is_staff());
create policy rq_staff  on research_queue for select using (is_staff());
create policy rq_edit   on research_queue for update using (has_platform_role(array['super_admin','admin','reviewer']::platform_role[])) with check (has_platform_role(array['super_admin','admin','reviewer']::platform_role[]));
create policy chg_staff on regulatory_changes for select using (is_staff());

-- documents + evidence: tenants may read current documents and evidence for active rules; staff read all
create policy doc_read  on regulatory_documents for select to authenticated using (status in ('current','superseded') or is_staff());
create policy doc_admin on regulatory_documents for all using (has_platform_role(array['super_admin','admin']::platform_role[])) with check (has_platform_role(array['super_admin','admin']::platform_role[]));
create policy ev_read   on rule_evidence for select to authenticated using (
  is_staff() or exists (select 1 from rule_versions v where v.id = rule_version_id and v.state in ('active','superseded')));

-- staff can also see draft / pending rule versions
create policy rv_staff  on rule_versions for select using (is_staff());

-- tenant data
create policy ddc_select on due_date_calculations for select using (
  exists (select 1 from obligations o where o.id = obligation_id and is_org_member(o.org_id)));
create policy rem_select on reminders for select using (is_org_member(org_id));
create policy rs_select  on reminder_settings for select using (is_org_member(org_id));
create policy rs_write   on reminder_settings for all using (is_org_admin(org_id)) with check (is_org_admin(org_id));
create policy ntf_select on notifications for select using (
  (org_id is not null and is_org_member(org_id) and (user_id is null or user_id = auth.uid())) or (org_id is null and is_staff()));
create policy ntf_update on notifications for update using (
  (org_id is not null and is_org_member(org_id) and (user_id is null or user_id = auth.uid()))) with check (
  (org_id is not null and is_org_member(org_id)));
-- audit log: staff may read rulebook-level entries
create policy audit_staff on audit_log for select using (org_id is null and is_staff());

-- ───────────── storage (Supabase) ─────────────
do $$ begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets(id, name, public) values ('regulatory-docs','regulatory-docs',false), ('client-evidence','client-evidence',false)
      on conflict (id) do nothing;
    -- regulatory documents: signed-in users read, staff admins write
    execute $p$create policy regdocs_read on storage.objects for select to authenticated using (bucket_id = 'regulatory-docs')$p$;
    execute $p$create policy regdocs_write on storage.objects for insert to authenticated with check (bucket_id = 'regulatory-docs' and public.has_platform_role(array['super_admin','admin']::public.platform_role[]))$p$;
    -- client evidence: first path segment is the org id -> <org_id>/<client_id>/<file>
    execute $p$create policy cliev_read on storage.objects for select to authenticated using (bucket_id = 'client-evidence' and public.is_org_member(((storage.foldername(name))[1])::uuid))$p$;
    execute $p$create policy cliev_write on storage.objects for insert to authenticated with check (bucket_id = 'client-evidence' and public.can_write_org(((storage.foldername(name))[1])::uuid))$p$;
    execute $p$create policy cliev_delete on storage.objects for delete to authenticated using (bucket_id = 'client-evidence' and public.can_write_org(((storage.foldername(name))[1])::uuid))$p$;
  end if;
end $$;
