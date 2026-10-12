-- REGULENTA — migration 004: obligation workflow, company profile and contacts, recipients and escalation,
-- notification events + delivery log, deadline engine (canonical schedules), regulatory-intelligence fields,
-- org-scoped audit, and security tightening.
--
-- STATUS: written and tested on a LOCAL Postgres 16 copy of the schema only. NOT applied to any Supabase project.
-- Applying it to Supabase needs the owner's separate written authorisation (standing rule).
-- Independent of the V3 drafts (STEP3a-3e, STEP5); it adds no rule_versions columns, so V3 step 3e's column grants
-- are unaffected whichever is applied first.
--
-- Principles enforced in the database (not just the UI):
--  * An obligation's workflow stage changes ONLY through transition_obligation(); no direct status/stage edits.
--  * Due dates change ONLY through extend_obligation() (recorded reason) or a rule-version recalculation.
--  * Obligations are created ONLY by the deadline engine from ACTIVE, human-approved rule versions.
--  * Definitive deadline reminders go to clients ONLY for obligations whose rule version is active, approved
--    and has primary evidence attached; anything else becomes a staff "review required" alert.
--  * Email recipients must be explicitly configured; external contacts must have a verified email and opt-in.
--  * Every reminder event has an idempotency key; repeated or concurrent scheduler runs cannot duplicate it.

begin;

-- ════════════════════════════ 0. enums ════════════════════════════
create type obligation_stage as enum
  ('initiated','preparing','in_review','approved','executed','filed','evidence_pending','closed','cancelled','not_applicable');
create type obligation_lifecycle as enum ('proposed','active');
create type contact_role as enum ('compliance_owner','company_admin','company_secretary','compliance_officer','reviewer','management','other');
create type notif_trigger as enum
  ('upcoming','due_today','overdue','overdue_followup','escalation','overdue_repeat','not_started',
   'evidence_missing','approval_pending','filing_confirmation_pending','reopened','regulatory_change',
   'new_obligation','review_required');
create type notif_priority as enum ('low','normal','high','critical');
create type delivery_status as enum ('queued','sending','accepted','delivered','bounced','failed','suppressed');
create type legal_status as enum ('binding_act','delegated_legislation','official_guidance','draft_proposal','informational');
create type change_action as enum ('new','inserted','amended','substituted','omitted','repealed','clarified','commencement','corrigendum');

alter type notif_category add value if not exists 'escalation';
alter type notif_category add value if not exists 'evidence_missing';
alter type notif_category add value if not exists 'approval_pending';

-- ════════════════════════════ 1. company profile + contacts ════════════════════════════
alter table clients
  add column incorporation_date date,
  add column registered_office text,
  add column industry text,
  add column business_activities text[] not null default '{}',
  add column listed boolean,
  add column timezone text not null default 'Asia/Kolkata',
  add constraint clients_cin_format check (
    cin_or_llpin is null
    or cin_or_llpin ~ '^[LU][0-9]{5}[A-Z]{2}[0-9]{4}[A-Z]{3}[0-9]{6}$'      -- CIN (21 chars)
    or cin_or_llpin ~ '^[A-Z]{3}-[0-9]{4}$'                                  -- LLPIN (AAA-0000)
  ) not valid;   -- NOT VALID: existing rows (if any) are not re-checked; new and edited rows are

create or replace function check_client_timezone() returns trigger language plpgsql as $$
begin
  if not exists (select 1 from pg_timezone_names where name = new.timezone) then
    raise exception 'unknown time zone %', new.timezone using errcode = '22023';
  end if;
  return new;
end $$;
create trigger t_client_tz before insert or update of timezone on clients for each row execute function check_client_timezone();

create table client_contacts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs(id) on delete cascade,
  client_id uuid not null references clients(id) on delete cascade,
  full_name text not null check (length(trim(full_name)) > 0),
  email text not null check (email = lower(email) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  role contact_role not null default 'other',
  designation text,                       -- e.g. Director, CFO (informational only; does not authorise emails)
  notify_email boolean not null default false,   -- explicit opt-in by an org admin
  email_verified_at timestamptz,          -- set only by confirm_contact_email()
  verify_token_hash text,
  verify_sent_at timestamptz,
  active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (client_id, email)
);
create index on client_contacts (org_id, client_id);
create trigger t_contacts_upd before update on client_contacts for each row execute function set_updated_at();

-- contact must belong to the same org as its client
create or replace function check_contact_org() returns trigger language plpgsql as $$
begin
  if not exists (select 1 from clients where id = new.client_id and org_id = new.org_id) then
    raise exception 'contact org does not match client org';
  end if;
  -- changing the email address invalidates the previous verification
  if tg_op = 'UPDATE' and new.email is distinct from old.email then
    new.email_verified_at := null; new.verify_token_hash := null;
  end if;
  -- verification fields are owned by the verification functions (request/confirm), never by direct writes
  if tg_op = 'UPDATE' and coalesce(current_setting('regulenta.verifying', true), '') <> 'on'
     and new.email is not distinct from old.email
     and (new.email_verified_at is distinct from old.email_verified_at or new.verify_token_hash is distinct from old.verify_token_hash
          or new.verify_sent_at is distinct from old.verify_sent_at) then
    raise exception 'email verification can only be recorded by confirm_contact_email()' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and new.email is distinct from old.email then
    new.verify_sent_at := null;
  end if;
  if tg_op = 'INSERT' and coalesce(current_setting('regulenta.verifying', true), '') <> 'on' then
    new.email_verified_at := null; new.verify_token_hash := null; new.verify_sent_at := null;
  end if;
  return new;
end $$;
create trigger t_contact_org before insert or update on client_contacts for each row execute function check_contact_org();

-- ════════════════════════════ 2. recipients, schedules, escalation config ════════════════════════════
create table notification_recipients (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs(id) on delete cascade,
  client_id uuid references clients(id) on delete cascade,             -- null = all companies in the org
  user_id uuid references auth.users(id) on delete cascade,             -- an org member ...
  contact_id uuid references client_contacts(id) on delete cascade,     -- ... or a company contact
  escalation_level smallint not null default 0 check (escalation_level between 0 and 2),
  -- 0 = first reminders (owner), 1 = compliance officer (first escalation), 2 = management (further escalation)
  channels text[] not null default '{email,in_app}' check (channels <@ array['email','in_app']),
  triggers notif_trigger[],                                             -- null = all trigger types
  active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check ((user_id is null) <> (contact_id is null))
);
create unique index notification_recipients_uniq on notification_recipients
  (org_id, coalesce(client_id,'00000000-0000-0000-0000-000000000000'::uuid),
   coalesce(user_id,'00000000-0000-0000-0000-000000000000'::uuid),
   coalesce(contact_id,'00000000-0000-0000-0000-000000000000'::uuid));

create or replace function check_recipient() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.user_id is not null and not exists (select 1 from org_members where org_id = new.org_id and user_id = new.user_id) then
    raise exception 'recipient user is not a member of this organisation';
  end if;
  if new.contact_id is not null and not exists (
       select 1 from client_contacts k where k.id = new.contact_id and k.org_id = new.org_id
         and (new.client_id is null or k.client_id = new.client_id)) then
    raise exception 'recipient contact does not belong to this organisation/company';
  end if;
  if new.client_id is not null and not exists (select 1 from clients where id = new.client_id and org_id = new.org_id) then
    raise exception 'company does not belong to this organisation';
  end if;
  return new;
end $$;
create trigger t_recipient_check before insert or update on notification_recipients for each row execute function check_recipient();

alter table reminder_settings
  add column overdue_offsets int[] not null default '{1,3}',
  add column escalate_after_days int not null default 7 check (escalate_after_days >= 1),
  add column escalate_level2_after_days int not null default 14,
  add column repeat_every_days int not null default 7 check (repeat_every_days >= 1),
  add column email_enabled boolean not null default false,   -- org admin must switch on email for the org
  add constraint rs_level2_after_level1 check (escalate_level2_after_days > escalate_after_days),
  add constraint rs_offsets_nonneg check (0 <= all(offsets) and 1 <= all(overdue_offsets));

-- ════════════════════════════ 3. obligation workflow ════════════════════════════
alter table obligations
  add column stage obligation_stage not null default 'initiated',
  add column lifecycle obligation_lifecycle not null default 'proposed',
  add column requires_approval boolean not null default true,
  add column requires_evidence boolean not null default true,
  add column non_working_day boolean not null default false,
  add column closed_at timestamptz,
  add column reopened_count int not null default 0,
  add column activated_at timestamptz,
  add column activated_by uuid references auth.users(id),
  add column date_review_required boolean not null default false;   -- set when an amendment changes a periodic schedule

-- existing rows (none in live today) keep their meaning
update obligations set lifecycle = 'active',
  stage = case status when 'upcoming' then 'initiated' when 'in_progress' then 'preparing' when 'filed' then 'filed'
                      when 'not_applicable' then 'not_applicable' when 'waived' then 'cancelled' end::obligation_stage;

create table obligation_transitions (
  id bigint generated always as identity primary key,
  obligation_id uuid not null references obligations(id) on delete cascade,
  org_id uuid not null,
  from_stage obligation_stage,
  to_stage obligation_stage not null,
  actor uuid references auth.users(id),
  note text,
  reference_no text,
  at timestamptz not null default now()
);
create index on obligation_transitions (obligation_id, at);

-- Guard: stage/status/filing fields, due dates, rule version and lifecycle only change through the controlled functions.
create or replace function guard_obligation_update() returns trigger language plpgsql as $$
begin
  if (new.stage is distinct from old.stage or new.status is distinct from old.status or new.filed_on is distinct from old.filed_on
      or new.reference_no is distinct from old.reference_no or new.closed_at is distinct from old.closed_at
      or new.reopened_count is distinct from old.reopened_count
      or new.requires_approval is distinct from old.requires_approval or new.requires_evidence is distinct from old.requires_evidence)
     and coalesce(current_setting('regulenta.transition', true), '') <> 'on' then
    raise exception 'workflow fields change only through transition_obligation()' using errcode = '42501';
  end if;
  if (new.due_date is distinct from old.due_date or new.rule_version_id is distinct from old.rule_version_id
      or new.due_date_basis is distinct from old.due_date_basis or new.non_working_day is distinct from old.non_working_day
      or new.event_id is distinct from old.event_id or new.original_due_date is distinct from old.original_due_date)
     and coalesce(current_setting('regulenta.due_change', true), '') <> 'on' then
    raise exception 'due dates change only through extend_obligation() or an approved rule amendment' using errcode = '42501';
  end if;
  if new.assignee is distinct from old.assignee and new.assignee is not null
     and not exists (select 1 from org_members m where m.org_id = new.org_id and m.user_id = new.assignee) then
    raise exception 'the assignee must be a member of this organisation';
  end if;
  if new.created_at is distinct from old.created_at then
    raise exception 'created_at cannot be changed' using errcode = '42501';
  end if;
  if (new.lifecycle is distinct from old.lifecycle or new.activated_at is distinct from old.activated_at
      or new.activated_by is distinct from old.activated_by or new.date_review_required is distinct from old.date_review_required)
     and coalesce(current_setting('regulenta.activating', true), '') <> 'on' then
    raise exception 'obligations are activated only through activate_obligations()' using errcode = '42501';
  end if;
  if new.org_id is distinct from old.org_id or new.client_id is distinct from old.client_id or new.period_label is distinct from old.period_label then
    raise exception 'organisation, company and period of an obligation cannot be changed' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger t_guard_obligation before update on obligations for each row execute function guard_obligation_update();

-- Inserts only through the engine (security-definer functions set regulenta.generating).
create or replace function guard_obligation_insert() returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('regulenta.generating', true), '') <> 'on' then
    raise exception 'obligations are created only by the deadline engine from approved rules' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger t_guard_obligation_ins before insert on obligations for each row execute function guard_obligation_insert();

-- Tenants may update notes/assignee directly; no direct insert or delete.
drop policy if exists obl_write on obligations;
create policy obl_update on obligations for update using (can_write_org(org_id)) with check (can_write_org(org_id));

create or replace function stage_to_status(s obligation_stage) returns obligation_status language sql immutable as $$
  select case s when 'initiated' then 'upcoming' when 'preparing' then 'in_progress' when 'in_review' then 'in_progress'
                when 'approved' then 'in_progress' when 'executed' then 'in_progress' when 'filed' then 'filed'
                when 'evidence_pending' then 'filed' when 'closed' then 'filed' when 'cancelled' then 'waived'
                when 'not_applicable' then 'not_applicable' end::obligation_status
$$;

create or replace function obligation_open(s obligation_stage) returns boolean language sql immutable as $$
  select s not in ('closed','cancelled','not_applicable')
$$;

-- The single entry point for workflow changes.
create or replace function transition_obligation(p_obligation uuid, p_to obligation_stage, p_note text default null,
                                                 p_reference text default null)
returns obligation_stage language plpgsql security definer set search_path = public as $$
declare o obligations; ok boolean := false; submitter uuid; has_evidence boolean; approved_once boolean;
begin
  select * into o from obligations where id = p_obligation for update;
  if not found or not can_write_org(o.org_id) then
    raise exception 'obligation not found or not accessible' using errcode = '42501';
  end if;
  if o.lifecycle <> 'active' then raise exception 'obligation is proposed, not active; activate it first'; end if;

  ok := case
    when obligation_open(o.stage)     and p_to in ('cancelled','not_applicable') then true   -- admin + reason, checked below
    when o.stage = 'initiated'        and p_to in ('preparing') then true
    when o.stage = 'preparing'        and p_to in ('in_review') then true
    when o.stage = 'preparing'        and p_to in ('executed','filed') and not o.requires_approval then true
    when o.stage = 'in_review'        and p_to in ('approved','preparing') then true
    when o.stage = 'approved'         and p_to in ('executed','filed','preparing') then true
    when o.stage = 'executed'         and p_to in ('filed') then true
    when o.stage = 'filed'            and p_to in ('evidence_pending','closed') then true
    when o.stage = 'evidence_pending' and p_to in ('closed') then true
    when o.stage in ('filed','evidence_pending','closed','cancelled','not_applicable') and p_to = 'preparing' then true  -- reopen
    else false end;
  if not ok then raise exception 'transition % → % is not allowed', o.stage, p_to; end if;

  if p_to in ('cancelled','not_applicable') then
    if not is_org_admin(o.org_id) then raise exception 'only an organisation admin may cancel or mark not applicable' using errcode = '42501'; end if;
    if coalesce(trim(p_note),'') = '' then raise exception 'a reason is required'; end if;
  end if;

  if p_to = 'approved' then
    if not is_org_admin(o.org_id) then raise exception 'only an organisation admin may approve' using errcode = '42501'; end if;
    select actor into submitter from obligation_transitions
     where obligation_id = o.id and to_stage = 'in_review' order by at desc, id desc limit 1;
    if submitter = auth.uid() then raise exception 'maker-checker: the person who submitted for review cannot approve' using errcode = '42501'; end if;
  end if;

  if p_to = 'filed' then
    if coalesce(trim(coalesce(p_reference, o.reference_no)),'') = '' then
      raise exception 'filing needs the acknowledgement / SRN / ARN reference';
    end if;
  end if;

  if p_to = 'closed' then
    select exists (select 1 from documents d where d.obligation_id = o.id) into has_evidence;
    if o.requires_evidence and not has_evidence then
      raise exception 'closing needs at least one evidence document attached';
    end if;
    select exists (select 1 from obligation_transitions t where t.obligation_id = o.id and t.to_stage = 'approved'
                     and t.at > coalesce((select max(at) from obligation_transitions r where r.obligation_id = o.id
                                            and r.from_stage in ('filed','evidence_pending','closed','cancelled','not_applicable')
                                            and r.to_stage = 'preparing'), '-infinity'))
      into approved_once;
    if o.requires_approval and not approved_once then
      raise exception 'closing needs the review approval step first';
    end if;
  end if;

  if p_to = 'preparing' and o.stage in ('filed','evidence_pending','closed','cancelled','not_applicable')
     and coalesce(trim(p_note),'') = '' then
    raise exception 'reopening needs a reason';
  end if;

  perform set_config('regulenta.transition', 'on', true);
  update obligations set
    stage = p_to,
    status = stage_to_status(p_to),
    reference_no = case when p_to = 'filed' then coalesce(nullif(trim(p_reference),''), reference_no) else reference_no end,
    filed_on = case when p_to = 'filed' then current_date
                    when p_to = 'preparing' and o.stage in ('filed','evidence_pending','closed') then null else filed_on end,
    closed_at = case when p_to = 'closed' then now() when p_to = 'preparing' then null else closed_at end,
    reopened_count = reopened_count + case when p_to = 'preparing' and o.stage in ('filed','evidence_pending','closed','cancelled','not_applicable') then 1 else 0 end
  where id = o.id;
  perform set_config('regulenta.transition', 'off', true);

  insert into obligation_transitions(obligation_id, org_id, from_stage, to_stage, actor, note, reference_no)
  values (o.id, o.org_id, o.stage, p_to, auth.uid(), p_note, p_reference);
  insert into audit_log(org_id, user_id, action, entity, entity_id, detail)
  values (o.org_id, auth.uid(), 'transition', 'obligation', o.id,
          jsonb_build_object('from', o.stage, 'to', p_to, 'note', p_note, 'reference', p_reference));

  -- reopened items resume reminders; record a 'reopened' event (idempotent per reopen count)
  if p_to = 'preparing' and o.stage in ('filed','evidence_pending','closed','cancelled','not_applicable') then
    perform raise_obligation_event(o.id, 'reopened', 'R' || (o.reopened_count + 1)::text, 'normal', current_date);
  end if;
  return p_to;
end $$;

-- Per-obligation workflow settings (approval / evidence requirement): org admins only, recorded.
create or replace function set_obligation_requirements(p_obligation uuid, p_requires_approval boolean, p_requires_evidence boolean, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare o obligations;
begin
  select * into o from obligations where id = p_obligation for update;
  if not found or not is_org_admin(o.org_id) then raise exception 'only an organisation admin may change requirements' using errcode = '42501'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'a reason is required'; end if;
  perform set_config('regulenta.transition', 'on', true);
  update obligations set requires_approval = p_requires_approval, requires_evidence = p_requires_evidence where id = o.id;
  perform set_config('regulenta.transition', 'off', true);
  insert into audit_log(org_id, user_id, action, entity, entity_id, detail)
  values (o.org_id, auth.uid(), 'requirements', 'obligation', o.id,
          jsonb_build_object('requires_approval', jsonb_build_array(o.requires_approval, p_requires_approval),
                             'requires_evidence', jsonb_build_array(o.requires_evidence, p_requires_evidence), 'reason', p_reason));
end $$;

-- extend_obligation: same signature as before, now also sets the due-change flag and requires a reason.
create or replace function extend_obligation(p_obligation uuid, p_new_date date, p_reason text, p_change uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare o obligations;
begin
  select * into o from obligations where id = p_obligation for update;
  if not found or not can_write_org(o.org_id) then raise exception 'obligation not found or not accessible' using errcode = '42501'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'a reason (e.g. the extension notification) is required'; end if;
  if p_new_date is null then raise exception 'new date required'; end if;
  perform set_config('regulenta.due_change', 'on', true);
  perform set_config('regulenta.activating', 'on', true);
  update obligations set due_date = p_new_date, date_review_required = false where id = p_obligation;
  perform set_config('regulenta.activating', 'off', true);
  perform set_config('regulenta.due_change', 'off', true);
  insert into due_date_calculations(obligation_id, kind, due_date, previous_due_date, explanation, change_id, created_by)
  values (p_obligation, 'extension', p_new_date, o.due_date, p_reason, p_change, auth.uid());
  insert into audit_log(org_id, user_id, action, entity, entity_id, detail)
  values (o.org_id, auth.uid(), 'due_date_change', 'obligation', o.id,
          jsonb_build_object('from', o.due_date, 'to', p_new_date, 'reason', p_reason, 'change', p_change));
end $$;

-- recalc_after_rule_change (called by approve_rule_change): same logic, with the due-change flag.
create or replace function recalc_after_rule_change(p_new uuid, p_old uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; o record; nv rule_versions; nd date; rid uuid;
begin
  select * into nv from rule_versions where id = p_new;
  rid := nv.rule_id;
  if nv.state <> 'active' or p_old is null then return 0; end if;
  perform set_config('regulenta.due_change', 'on', true);
  perform set_config('regulenta.activating', 'on', true);
  for o in select ob.*, e.event_date from obligations ob left join events e on e.id = ob.event_id
            where ob.rule_version_id = p_old and obligation_open(ob.stage)
              and (nv.effective_from is null or ob.due_date >= nv.effective_from) loop
    nd := o.due_date;
    if nv.kind = 'event' and o.event_date is not null then
      nd := case when coalesce(nv.schedule->>'day_type','calendar') = 'working'
                 then add_working_days(o.event_date, coalesce((nv.schedule->>'days')::int,0) * coalesce((nv.schedule->>'direction')::int,1))
                 else o.event_date + coalesce((nv.schedule->>'days')::int,0) * coalesce((nv.schedule->>'direction')::int,1) end;
    end if;
    update obligations set rule_version_id = p_new, due_date = nd,
           date_review_required = (nv.kind <> 'event' and nv.schedule is distinct from (select v.schedule from rule_versions v where v.id = p_old))
     where id = o.id;
    insert into due_date_calculations(obligation_id, kind, due_date, previous_due_date, explanation, rule_version_id)
    values (o.id, 'recalculation', nd, o.due_date,
            case when nv.kind <> 'event' and nv.schedule is distinct from (select v.schedule from rule_versions v where v.id = p_old)
                 then 'Rule amended and its schedule changed: the date must be re-confirmed before reminders resume'
                 else 'Recalculated after rule amendment (new version approved)' end, p_new);
    insert into notifications(org_id, category, title, body, client_id, obligation_id, rule_id)
    values (o.org_id, case when nd is distinct from o.due_date then 'due_date_change' else 'amendment' end::notif_category,
            case when nd is distinct from o.due_date then 'Deadline has changed' else 'This compliance requirement has been amended' end,
            format('Due date %s → %s', o.due_date, nd), o.client_id, o.id, rid);
    n := n + 1;
  end loop;
  perform set_config('regulenta.activating', 'off', true);
  perform set_config('regulenta.due_change', 'off', true);
  return n;
end $$;
revoke all on function recalc_after_rule_change(uuid, uuid) from public, anon, authenticated;

-- ════════════════════════════ 4. deadline engine (canonical schedules, spec v2) ════════════════════════════
-- Canonical schedule.type values (anything else is skipped with a reason; nothing is guessed):
--   monthly_day      {day, offset_months?=1, clamp_to_month_end?}
--   annual_fixed     {day, month}
--   annual_dates     {dates: ["MM-DD", ...]}
--   after_period_end {period: month|quarter|half_year|fy, days, day_type: calendar|working}
--   event_offset     {anchor, days, day_type, direction}   (created from events, not by date window)
--   manual           {note}                                (never generated)
-- Holiday rule: dates are never moved unless schedule.holiday_rule = 'next_working_day' AND schedule.holiday_source is set.

insert into system_settings(key, value) values ('deadline_generation_horizon_months', '15') on conflict (key) do nothing;

create or replace function is_non_working(d date) returns boolean language sql stable set search_path = public as $$
  select extract(isodow from d) >= 6 or exists (select 1 from holidays h where h.day = d)
$$;

create or replace function apply_holiday_rule(d date, s jsonb) returns date language plpgsql stable set search_path = public as $$
declare x date := d;
begin
  if s->>'holiday_rule' = 'next_working_day' and coalesce(s->>'holiday_source','') <> '' then
    while is_non_working(x) loop x := x + 1; end loop;
  end if;
  return x;
end $$;

-- period ends aligned to the company's financial year end month
create or replace function period_ends(p_period text, p_fy_end_month int, p_from date, p_to date)
returns table(period_end date, label text) language plpgsql stable as $$
declare step int; m date; anchor date; k int; months int;
begin
  step := case p_period when 'month' then 1 when 'quarter' then 3 when 'half_year' then 6 when 'fy' then 12 else null end;
  if step is null then return; end if;
  -- first month-end of a period boundary on/after p_from - 13 months (covers due dates in window from earlier periods)
  anchor := (make_date(extract(year from p_from)::int - 2, p_fy_end_month, 1) + interval '1 month' - interval '1 day')::date;
  k := 0;
  loop
    m := (date_trunc('month', anchor) + make_interval(months => k * step) + interval '1 month' - interval '1 day')::date;
    exit when m > p_to;
    if m >= p_from - interval '13 months' then
      months := ((extract(year from m) - extract(year from anchor)) * 12 + extract(month from m) - extract(month from anchor))::int;
      label := case p_period
        when 'month' then to_char(m, 'Mon YYYY')
        when 'fy' then 'FY ' || (extract(year from m)::int - 1) || '-' || to_char(m, 'YY')
        when 'quarter' then 'Quarter ending ' || to_char(m, 'DD Mon YYYY')
        when 'half_year' then 'Half-year ending ' || to_char(m, 'DD Mon YYYY') end;
      period_end := m;
      return next;
    end if;
    k := k + 1;
  end loop;
end $$;

-- Preview: what would be generated. Nothing is saved. Members of the company's org only.
create or replace function preview_obligations(p_client uuid, p_from date default current_date, p_to date default null)
returns table(rule_version_id uuid, rule_key text, title text, period_label text, due_date date, basis text,
              non_working_day boolean, action text, reason text)
language plpgsql stable security definer set search_path = public as $$
declare c clients; rv record; s jsonb; t text; horizon int; v_to date; y int; md text; d date; m date; pe record;
        appl record; lbl text; bas text; dd int;
begin
  select * into c from clients where id = p_client;
  if not found or not is_org_member(c.org_id) then raise exception 'company not found or not accessible' using errcode = '42501'; end if;
  horizon := least(coalesce((select (value #>> '{}')::int from system_settings where key = 'deadline_generation_horizon_months'), 15), 36);
  v_to := coalesce(p_to, (p_from + make_interval(months => horizon))::date);
  if v_to > (p_from + interval '36 months')::date then raise exception 'window larger than 36 months'; end if;

  for rv in
    select v.*, r.rule_key as rk, r.title as rt from rule_versions v join rules r on r.id = v.rule_id
     where v.state = 'active' and v.approved_at is not null
       and (v.effective_from is null or v.effective_from <= v_to)
       and (v.effective_until is null or v.effective_until >= p_from)
     order by r.rule_key
  loop
    s := coalesce(rv.schedule, '{}'::jsonb); t := s->>'type';
    rule_version_id := rv.id; rule_key := rv.rk; title := rv.rt;
    period_label := null; due_date := null; basis := null; non_working_day := null;

    if not exists (select 1 from rule_evidence e where e.rule_version_id = rv.id) then
      action := 'skip'; reason := 'no primary evidence attached to the active rule version'; return next; continue;
    end if;

    select * into appl from evaluate_applicability(c.id, rv.id);
    if appl.result = 'not_applicable' then continue; end if;
    if appl.result = 'review_required' then
      action := 'review_required'; reason := appl.reasons::text; return next; continue;
    end if;

    if t is null or t not in ('monthly_day','annual_fixed','annual_dates','after_period_end','event_offset','manual') then
      action := 'skip'; reason := format('non-canonical schedule %s — convert during review', s); return next; continue;
    end if;
    if t = 'manual' then action := 'skip'; reason := 'manual schedule: enter by hand'; return next; continue; end if;
    if t = 'event_offset' then action := 'skip'; reason := 'event-based: created when the event date is recorded'; return next; continue; end if;

    for lbl, d, bas in
      -- monthly_day: obligation for month M due on day D of month M + offset
      select to_char(gs, 'Mon YYYY'),
             case when (s->>'day')::int <= extract(day from (date_trunc('month', gs + make_interval(months => coalesce((s->>'offset_months')::int,1))) + interval '1 month - 1 day'))::int
                  then (date_trunc('month', gs + make_interval(months => coalesce((s->>'offset_months')::int,1))))::date + ((s->>'day')::int - 1)
                  when coalesce((s->>'clamp_to_month_end')::boolean, false)
                  then (date_trunc('month', gs + make_interval(months => coalesce((s->>'offset_months')::int,1))) + interval '1 month - 1 day')::date
                  else null end,
             format('day %s of the month after the period (offset %s month)', s->>'day', coalesce(s->>'offset_months','1'))
        from generate_series(date_trunc('month', p_from) - interval '13 months', date_trunc('month', v_to), interval '1 month') gs
       where t = 'monthly_day'
      union all
      select 'Due ' || y2 || '-' || lpad(s->>'month',2,'0') || '-' || lpad(s->>'day',2,'0'),
             make_date(y2, (s->>'month')::int, (s->>'day')::int), 'fixed annual date'
        from generate_series(extract(year from p_from)::int, extract(year from v_to)::int) y2
       where t = 'annual_fixed'
      union all
      select 'Due ' || y2 || '-' || md2, make_date(y2, split_part(md2,'-',1)::int, split_part(md2,'-',2)::int), 'fixed date list'
        from generate_series(extract(year from p_from)::int, extract(year from v_to)::int) y2,
             jsonb_array_elements_text(case when t = 'annual_dates' then s->'dates' else '[]'::jsonb end) md2
       where t = 'annual_dates'
      union all
      select pe2.label,
             case when coalesce(s->>'day_type','calendar') = 'working' then add_working_days(pe2.period_end, (s->>'days')::int)
                  else pe2.period_end + (s->>'days')::int end,
             format('%s end + %s %s days', s->>'period', s->>'days', coalesce(s->>'day_type','calendar'))
        from period_ends(case when t = 'after_period_end' then s->>'period' else 'none' end, c.fy_end_month, p_from, v_to) pe2
       where t = 'after_period_end'
    loop
      if d is null then
        action := 'skip'; reason := format('day %s does not exist in that month and clamp_to_month_end is not set', s->>'day');
        period_label := lbl; due_date := null; basis := bas; return next; continue;
      end if;
      d := apply_holiday_rule(d, s);
      if d < p_from or d > v_to then continue; end if;
      if rv.effective_from is not null and d < rv.effective_from then continue; end if;
      if rv.effective_until is not null and d > rv.effective_until then continue; end if;
      period_label := lbl; due_date := d; basis := bas; non_working_day := is_non_working(d);
      if exists (select 1 from obligations o where o.client_id = c.id and o.rule_version_id = rv.id and o.period_label = lbl) then
        action := 'exists'; reason := null;
      elsif exists (select 1 from obligations o join rule_versions v2 on v2.id = o.rule_version_id
                     where o.client_id = c.id and v2.rule_id = rv.rule_id and o.period_label = lbl) then
        action := 'exists'; reason := 'already tracked under an earlier version of this rule';
      else
        action := 'create'; reason := case when is_non_working(d) then 'falls on a non-working day: verify whether an extension or holiday rule applies' end;
      end if;
      return next;
    end loop;
  end loop;
end $$;

-- Generate: saves the 'create' rows from preview as PROPOSED obligations (no reminders until activated).
create or replace function generate_obligations(p_client uuid, p_from date default current_date, p_to date default null)
returns int language plpgsql security definer set search_path = public as $$
declare c clients; r record; made int := 0; cnt int;
begin
  select * into c from clients where id = p_client;
  if not found or not can_write_org(c.org_id) then raise exception 'company not found or not accessible' using errcode = '42501'; end if;
  perform set_config('regulenta.generating', 'on', true);
  for r in select * from preview_obligations(p_client, p_from, p_to) where action = 'create' loop
    insert into obligations(org_id, client_id, rule_version_id, period_label, due_date, due_date_basis, non_working_day, lifecycle, stage, status)
    values (c.org_id, c.id, r.rule_version_id, r.period_label, r.due_date, r.basis, r.non_working_day, 'proposed', 'initiated', 'upcoming')
    on conflict (client_id, rule_version_id, period_label) do nothing;
    get diagnostics cnt = row_count; made := made + cnt;
  end loop;
  perform set_config('regulenta.generating', 'off', true);
  insert into audit_log(org_id, user_id, action, entity, entity_id, detail)
  values (c.org_id, auth.uid(), 'generate', 'client', c.id, jsonb_build_object('created', made, 'from', p_from, 'to', p_to));
  return made;
end $$;

-- Activate proposed obligations (owner confirms). Reminders only ever fire for active ones.
create or replace function activate_obligations(p_client uuid, p_ids uuid[] default null)
returns int language plpgsql security definer set search_path = public as $$
declare c clients; n int;
begin
  select * into c from clients where id = p_client;
  if not found or not is_org_admin(c.org_id) then raise exception 'only an organisation admin may activate deadlines' using errcode = '42501'; end if;
  perform set_config('regulenta.activating', 'on', true);
  update obligations set lifecycle = 'active', activated_at = now(), activated_by = auth.uid()
   where client_id = c.id and lifecycle = 'proposed' and (p_ids is null or id = any(p_ids));
  get diagnostics n = row_count;
  perform set_config('regulenta.activating', 'off', true);
  insert into audit_log(org_id, user_id, action, entity, entity_id, detail)
  values (c.org_id, auth.uid(), 'activate', 'client', c.id, jsonb_build_object('activated', n));
  return n;
end $$;

-- Discard proposed (never-activated) obligations, e.g. after a wrong profile answer.
create or replace function discard_proposed_obligations(p_client uuid, p_ids uuid[] default null)
returns int language plpgsql security definer set search_path = public as $$
declare c clients; n int;
begin
  select * into c from clients where id = p_client;
  if not found or not is_org_admin(c.org_id) then raise exception 'only an organisation admin may discard proposed deadlines' using errcode = '42501'; end if;
  delete from obligations where client_id = c.id and lifecycle = 'proposed' and (p_ids is null or id = any(p_ids));
  get diagnostics n = row_count;
  insert into audit_log(org_id, user_id, action, entity, entity_id, detail)
  values (c.org_id, auth.uid(), 'discard_proposed', 'client', c.id, jsonb_build_object('discarded', n));
  return n;
end $$;

-- Event-based obligations (e.g. AGM + 30 days): recorded event → proposed obligation. Canonical event_offset only.
create or replace function create_event_obligation(p_client uuid, p_rule_key text, p_event_date date, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare c clients; rv rule_versions; ev uuid; due date; ob uuid; s jsonb; n int; wd boolean; appl record;
begin
  select * into c from clients where id = p_client;
  if not found or not can_write_org(c.org_id) then raise exception 'company not found or not accessible' using errcode = '42501'; end if;
  select v.* into rv from rule_versions v join rules r on r.id = v.rule_id
   where r.rule_key = p_rule_key and v.state = 'active' and v.approved_at is not null;
  if not found then raise exception 'no active approved rule %', p_rule_key; end if;
  if not exists (select 1 from rule_evidence e where e.rule_version_id = rv.id) then raise exception 'rule % has no primary evidence attached', p_rule_key; end if;
  s := rv.schedule;
  if s->>'type' is distinct from 'event_offset' then raise exception 'rule % is not an event_offset schedule', p_rule_key; end if;
  select * into appl from evaluate_applicability(c.id, rv.id);
  if appl.result <> 'applicable' then raise exception 'rule % is % for this company: %', p_rule_key, appl.result, appl.reasons; end if;
  n  := coalesce((s->>'days')::int, 0) * coalesce((s->>'direction')::int, 1);
  wd := coalesce(s->>'day_type','calendar') = 'working';
  due := apply_holiday_rule(case when wd then add_working_days(p_event_date, n) else p_event_date + n end, s);

  insert into events(org_id, client_id, trigger_event, event_date, note, created_by)
  values (c.org_id, c.id, coalesce(s->>'anchor', rv.trigger_event, p_rule_key), p_event_date, p_note, auth.uid())
  returning id into ev;
  perform set_config('regulenta.generating', 'on', true);
  insert into obligations(org_id, client_id, rule_version_id, event_id, period_label, due_date, due_date_basis, non_working_day, lifecycle)
  values (c.org_id, c.id, rv.id, ev, coalesce(s->>'anchor','event') || ' ' || to_char(p_event_date,'YYYY-MM-DD'), due,
          format('%s %s %s %s %s days', coalesce(s->>'anchor','event'), p_event_date, case when n < 0 then '-' else '+' end, abs(n),
                 case when wd then 'working' else 'calendar' end), is_non_working(due), 'proposed')
  returning id into ob;
  perform set_config('regulenta.generating', 'off', true);
  return ob;
end $$;

-- legacy generator (security invoker, non-canonical schedules) is retired
create or replace function generate_fixed_obligations(p_client uuid, p_from date, p_to date)
returns int language plpgsql as $$
begin raise exception 'generate_fixed_obligations is retired; use preview_obligations / generate_obligations'; end $$;

-- ════════════════════════════ 5. notification events + delivery log ════════════════════════════
create table notification_events (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references orgs(id) on delete cascade,          -- null = platform staff event
  client_id uuid references clients(id) on delete cascade,
  obligation_id uuid references obligations(id) on delete cascade,
  change_id uuid references regulatory_changes(id) on delete set null,
  trigger_type notif_trigger not null,
  stage_key text not null,                                      -- e.g. D-30, D0, O+1, O+7, O+14, R1, W2
  escalation_level smallint not null default 0,
  priority notif_priority not null default 'normal',
  due_date_snapshot date,
  verification_status text not null check (verification_status in ('approved_rule','unverified','not_applicable')),
  event_date date not null,
  idempotency_key text not null unique,
  status text not null default 'open' check (status in ('open','suppressed')),
  suppression_reason text,
  created_at timestamptz not null default now()
);
create index on notification_events (org_id, created_at desc);
create index on notification_events (obligation_id, created_at desc);

create table notification_deliveries (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references notification_events(id) on delete cascade,
  org_id uuid references orgs(id) on delete cascade,
  channel text not null check (channel in ('email','in_app')),
  recipient_user_id uuid references auth.users(id) on delete set null,
  recipient_contact_id uuid references client_contacts(id) on delete set null,
  email_snapshot text,                                          -- address at queue time (email channel)
  escalation_level smallint not null default 0,
  status delivery_status not null default 'queued',
  attempts int not null default 0,
  max_attempts int not null default 5,
  next_attempt_at timestamptz not null default now(),
  provider text,
  provider_message_id text,
  last_error text,
  sent_at timestamptz,                                          -- provider accepted the request
  delivered_at timestamptz,                                     -- provider confirmed delivery (webhook)
  notification_id uuid references notifications(id) on delete set null,   -- in-app row
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index notification_deliveries_uniq on notification_deliveries
  (event_id, channel, coalesce(recipient_user_id,'00000000-0000-0000-0000-000000000000'::uuid),
   coalesce(recipient_contact_id,'00000000-0000-0000-0000-000000000000'::uuid));
create index notification_deliveries_due on notification_deliveries (next_attempt_at) where status = 'queued' and channel = 'email';
create unique index notification_deliveries_msgid on notification_deliveries (provider, provider_message_id) where provider_message_id is not null;
create trigger t_deliv_upd before update on notification_deliveries for each row execute function set_updated_at();

create table escalation_history (
  id bigint generated always as identity primary key,
  event_id uuid not null references notification_events(id) on delete cascade,
  org_id uuid references orgs(id) on delete cascade,
  obligation_id uuid references obligations(id) on delete cascade,
  from_level smallint not null,
  to_level smallint not null,
  original_recipients jsonb not null default '[]',
  escalated_recipients jsonb not null default '[]',
  reason text not null,
  at timestamptz not null default now()
);

alter table notifications
  add column event_id uuid references notification_events(id) on delete set null,
  add column priority notif_priority;

create table scheduler_runs (
  id bigint generated always as identity primary key,
  job text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  ok boolean,
  detail jsonb
);

-- a rule version is "verified" for client reminders only if active, approved and backed by primary evidence
create or replace function rule_version_verified(p_rv uuid, p_on date default current_date) returns boolean
language sql stable set search_path = public as $$
  select exists (select 1 from rule_versions v where v.id = p_rv and v.approved_at is not null and v.approved_by is not null
                   and (v.state = 'active'
                        -- superseded by an approved amendment that is not yet in force: the old text still governs until then
                        or (v.state = 'superseded' and v.effective_until is not null and p_on < v.effective_until
                            and exists (select 1 from rule_versions n where n.rule_id = v.rule_id and n.state = 'not_yet_effective'))))
     and exists (select 1 from rule_evidence e where e.rule_version_id = p_rv)
$$;

-- Daily: bring approved, future-dated rule versions into force on their effective date and move affected open obligations.
create or replace function activate_scheduled_rule_versions(p_today date default current_date) returns int
language plpgsql security definer set search_path = public as $$
declare v record; old_id uuid; n int := 0;
begin
  for v in select * from rule_versions where state = 'not_yet_effective' and effective_from <= p_today and approved_at is not null for update loop
    select id into old_id from rule_versions where rule_id = v.rule_id and state = 'superseded' and effective_until = v.effective_from
      order by version desc limit 1;
    perform set_config('regulenta.approving', 'on', true);
    update rule_versions set state = 'active' where id = v.id;
    perform set_config('regulenta.approving', 'off', true);
    insert into audit_log(action, entity, entity_id, detail)
    values ('scheduled_activation', 'rule_version', v.id, jsonb_build_object('previous_version', old_id, 'effective_from', v.effective_from));
    if old_id is not null then perform recalc_after_rule_change(v.id, old_id); end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- reminder settings for a company: client row, else org default, else system defaults
create or replace function effective_reminder_settings(p_org uuid, p_client uuid)
returns table(offsets int[], overdue_offsets int[], escalate_after_days int, escalate_level2_after_days int,
              repeat_every_days int, channels text[], email_enabled boolean)
language sql stable set search_path = public as $$
  select coalesce(c.offsets, o.offsets, '{30,15,7,3,1}'),
         coalesce(c.overdue_offsets, o.overdue_offsets, '{1,3}'),
         coalesce(c.escalate_after_days, o.escalate_after_days, 7),
         coalesce(c.escalate_level2_after_days, o.escalate_level2_after_days, 14),
         coalesce(c.repeat_every_days, o.repeat_every_days, 7),
         coalesce(c.channels, o.channels, '{in_app,email}'),
         coalesce(o.email_enabled, false)       -- the org switch governs email for all its companies
    from (select 1) one
    left join reminder_settings o on o.org_id = p_org and o.client_id is null
    left join reminder_settings c on c.org_id = p_org and c.client_id = p_client
$$;

create or replace function trigger_category(t notif_trigger) returns notif_category language sql immutable as $$
  select case
    when t in ('upcoming','due_today','not_started','filing_confirmation_pending','reopened') then 'compliance_reminder'
    when t in ('overdue','overdue_followup','overdue_repeat') then 'overdue'
    when t = 'escalation' then 'escalation'
    when t = 'evidence_missing' then 'evidence_missing'
    when t = 'approval_pending' then 'approval_pending'
    when t = 'regulatory_change' then 'amendment'
    when t = 'new_obligation' then 'new_compliance'
    else 'review_required' end::notif_category
$$;

create or replace function trigger_action(t notif_trigger) returns text language sql immutable as $$
  select case t
    when 'upcoming' then 'Prepare the filing and supporting documents before the due date.'
    when 'due_today' then 'Complete and file today, then record the acknowledgement reference.'
    when 'overdue' then 'This item is past its due date. Complete it as soon as possible and record the filing.'
    when 'overdue_followup' then 'Still outstanding after the due date. Please complete and record the filing.'
    when 'escalation' then 'Escalated: still outstanding. Please follow up with the responsible person.'
    when 'overdue_repeat' then 'Still outstanding. Please complete and record the filing.'
    when 'not_started' then 'Work has not started on this item. Please begin preparation.'
    when 'evidence_missing' then 'Upload the filing acknowledgement or other supporting evidence to close this item.'
    when 'approval_pending' then 'This item is waiting for review and approval.'
    when 'filing_confirmation_pending' then 'Confirm the filing status and record the acknowledgement reference.'
    when 'reopened' then 'This item was reopened. Review the reason and complete the outstanding steps.'
    when 'regulatory_change' then 'A verified regulatory change may affect this item. Review the change.'
    when 'new_obligation' then 'A new compliance item applies. Review and assign it.'
    else 'Verification required before this can be shown as a statutory deadline.' end
$$;

-- Create one event (idempotent) and its deliveries to authorised recipients. Returns the event id or null if it existed.
create or replace function raise_obligation_event(p_obligation uuid, p_trigger notif_trigger, p_stage text,
                                                  p_priority notif_priority, p_today date, p_level smallint default 0)
returns uuid language plpgsql security definer set search_path = public as $$
declare o obligations; c clients; ev uuid; key text; st record; verified boolean; r record; title text; body text;
        rk text; rtitle text; n_id uuid; recips jsonb := '[]'; lower_recips jsonb := '[]'; staff_only boolean;
begin
  select * into o from obligations where id = p_obligation;
  if not found then return null; end if;
  select * into c from clients where id = o.client_id;
  select ru.form, ru.title into rk, rtitle from rule_versions v join rules ru on ru.id = v.rule_id where v.id = o.rule_version_id;
  verified := rule_version_verified(o.rule_version_id, coalesce(p_today, current_date));
  staff_only := (p_trigger = 'review_required');
  key := concat_ws('|', o.id, p_trigger, p_stage, o.due_date);

  insert into notification_events(org_id, client_id, obligation_id, trigger_type, stage_key, escalation_level, priority,
                                  due_date_snapshot, verification_status, event_date, idempotency_key)
  values (case when staff_only then null else o.org_id end, o.client_id, o.id, p_trigger, p_stage, p_level, p_priority,
          o.due_date, case when verified then 'approved_rule' else 'unverified' end, p_today, key)
  on conflict (idempotency_key) do nothing
  returning id into ev;
  if ev is null then return null; end if;

  title := case
    when staff_only then format('Review required: %s for %s has no verified rule', coalesce(rk, rtitle), c.name)
    when p_trigger in ('overdue','overdue_followup','escalation','overdue_repeat') then format('[OVERDUE] %s — %s', c.name, coalesce(rk, rtitle))
    when p_trigger = 'due_today' then format('[DUE TODAY] %s — %s', c.name, coalesce(rk, rtitle))
    else format('%s — %s', c.name, coalesce(rk, rtitle)) end;
  body := format('%s · due %s · %s', coalesce(rtitle, rk), to_char(o.due_date, 'DD Mon YYYY'), trigger_action(p_trigger));

  if staff_only then
    insert into notifications(org_id, user_id, category, title, body, client_id, obligation_id, event_id, priority)
    values (null, null, 'review_required', title, body, o.client_id, o.id, ev, p_priority)
    returning id into n_id;
    insert into notification_deliveries(event_id, org_id, channel, status, delivered_at, notification_id)
    values (ev, null, 'in_app', 'delivered', now(), n_id);
    return ev;
  end if;

  select * into st from effective_reminder_settings(o.org_id, o.client_id);

  -- recipients: configured recipients up to this level (+ the assignee as level 0); external contacts need opt-in + verified email
  for r in
    with configured as (
      select nr.user_id, nr.contact_id, nr.escalation_level as lvl, nr.channels
        from notification_recipients nr
       where nr.org_id = o.org_id and nr.active
         and (nr.client_id is null or nr.client_id = o.client_id)
         and nr.escalation_level <= p_level
         and (nr.triggers is null or p_trigger = any(nr.triggers))
      union all
      select o.assignee, null, 0::smallint, '{email,in_app}'::text[]
       where o.assignee is not null
    )
    select distinct on (coalesce(cf.user_id, cf.contact_id))
           cf.user_id, cf.contact_id, cf.lvl, cf.channels,
           coalesce(u.email, k.email) as email,
           case when cf.contact_id is null then (m.user_id is not null)
                else (k.active and k.notify_email and k.email_verified_at is not null and k.client_id = o.client_id) end as email_ok,
           (cf.user_id is not null and m.user_id is not null) as in_app_ok
      from configured cf
      left join org_members m on m.org_id = o.org_id and m.user_id = cf.user_id
      left join auth.users u on u.id = cf.user_id
      left join client_contacts k on k.id = cf.contact_id
     order by coalesce(cf.user_id, cf.contact_id), cf.lvl
  loop
    if r.in_app_ok and 'in_app' = any(r.channels) and 'in_app' = any(st.channels) then
      insert into notifications(org_id, user_id, category, title, body, client_id, obligation_id, event_id, priority)
      values (o.org_id, r.user_id, trigger_category(p_trigger), title, body, o.client_id, o.id, ev, p_priority)
      returning id into n_id;
      insert into notification_deliveries(event_id, org_id, channel, recipient_user_id, escalation_level, status, delivered_at, notification_id)
      values (ev, o.org_id, 'in_app', r.user_id, r.lvl, 'delivered', now(), n_id)
      on conflict do nothing;
    end if;
    if r.email_ok and r.email is not null and 'email' = any(r.channels) and 'email' = any(st.channels) then
      insert into notification_deliveries(event_id, org_id, channel, recipient_user_id, recipient_contact_id, email_snapshot,
                                          escalation_level, status)
      values (ev, o.org_id, 'email', r.user_id, r.contact_id, r.email, r.lvl,
              case when st.email_enabled then 'queued' else 'suppressed' end::delivery_status)
      on conflict do nothing;
      if not st.email_enabled then
        update notification_deliveries set last_error = 'email disabled for this organisation'
         where event_id = ev and channel = 'email' and coalesce(recipient_user_id, recipient_contact_id) = coalesce(r.user_id, r.contact_id);
      end if;
    end if;
    if r.lvl < p_level then lower_recips := lower_recips || jsonb_build_array(coalesce(r.user_id, r.contact_id));
    else recips := recips || jsonb_build_array(coalesce(r.user_id, r.contact_id)); end if;
  end loop;

  -- nobody configured: org-wide in-app notice so the alert is never silently lost
  if not exists (select 1 from notification_deliveries d where d.event_id = ev) then
    insert into notifications(org_id, user_id, category, title, body, client_id, obligation_id, event_id, priority)
    values (o.org_id, null, trigger_category(p_trigger), title, body || ' (No reminder recipient is configured for this company.)',
            o.client_id, o.id, ev, p_priority)
    returning id into n_id;
    insert into notification_deliveries(event_id, org_id, channel, status, delivered_at, notification_id, last_error)
    values (ev, o.org_id, 'in_app', 'delivered', now(), n_id, 'no configured recipient: shown to the whole organisation');
  end if;

  if p_level > 0 then
    insert into escalation_history(event_id, org_id, obligation_id, from_level, to_level, original_recipients, escalated_recipients, reason)
    values (ev, o.org_id, o.id, p_level - 1, p_level, lower_recips, recips,
            format('%s days overdue', p_today - o.due_date));
  end if;
  return ev;
end $$;

-- The scheduler. Run daily (pg_cron) by the service role. Safe to run repeatedly or concurrently.
create or replace function generate_notification_events(p_today date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o record; st record; today date; days int; od int; thr int; made int := 0; skipped int := 0; review int := 0;
        ev uuid; run_id bigint; lvl smallint; stage text; trig notif_trigger; prio notif_priority;
begin
  if not pg_try_advisory_xact_lock(hashtext('regulenta.generate_notification_events')) then
    return jsonb_build_object('skipped', 'another run is in progress');
  end if;
  insert into scheduler_runs(job) values ('generate_notification_events') returning id into run_id;

  for o in
    select ob.*, cl.timezone from obligations ob join clients cl on cl.id = ob.client_id
     where ob.lifecycle = 'active' and obligation_open(ob.stage) and cl.archived_at is null
  loop
    today := coalesce(p_today, (now() at time zone coalesce(o.timezone, 'Asia/Kolkata'))::date);
    days := o.due_date - today;

    -- unverified rule version: staff review alert only, never a client deadline reminder
    if not rule_version_verified(o.rule_version_id, coalesce(p_today, current_date)) then
      ev := raise_obligation_event(o.id, 'review_required', 'V', 'high', today);
      if ev is not null then review := review + 1; end if;
      continue;
    end if;

    select * into st from effective_reminder_settings(o.org_id, o.client_id);
    stage := null; trig := null; lvl := 0;

    if days > 0 then
      -- most recent upcoming threshold reached (catches up if a run was missed)
      select min(x) into thr from unnest(st.offsets) x where x >= days and x > 0;
      if thr is not null then
        stage := 'D-' || thr; trig := 'upcoming';
        prio := case when thr >= 15 then 'low' when thr >= 7 then 'normal' else 'high' end;
      end if;
    elsif days = 0 then
      stage := 'D0'; trig := 'due_today'; prio := 'high';
    elsif o.stage in ('initiated','preparing','in_review','approved','executed') then
      od := -days;
      if od >= st.escalate_after_days then
        -- escalation at escalate_after_days, then a repeat every repeat_every_days; level 2 from escalate_level2_after_days
        thr := st.escalate_after_days + ((od - st.escalate_after_days) / st.repeat_every_days) * st.repeat_every_days;
        stage := 'O+' || thr;
        trig := case when thr = st.escalate_after_days then 'escalation' else 'overdue_repeat' end;
        lvl := case when od >= st.escalate_level2_after_days then 2 else 1 end;
        prio := 'critical';
      else
        select max(x) into thr from unnest(st.overdue_offsets) x where x <= od;
        if thr is not null then
          stage := 'O+' || thr;
          trig := case when thr = (select min(x) from unnest(st.overdue_offsets) x) then 'overdue' else 'overdue_followup' end;
          prio := 'critical';
        end if;
      end if;
    end if;

    if stage is not null then
      ev := raise_obligation_event(o.id, trig, stage, prio, today, lvl);
      if ev is not null then made := made + 1; else skipped := skipped + 1; end if;
    end if;

    -- workflow-based reminders (weekly while the condition lasts)
    if o.stage = 'initiated' and days between 0 and 7 then
      ev := raise_obligation_event(o.id, 'not_started', 'NS', 'normal', today);
      if ev is not null then made := made + 1; end if;
    end if;
    if o.stage in ('filed','evidence_pending') and o.requires_evidence
       and not exists (select 1 from documents d where d.obligation_id = o.id) then
      ev := raise_obligation_event(o.id, 'evidence_missing',
              'W' || ((today - coalesce(o.filed_on, today)) / 7)::text, 'normal', today);
      if ev is not null then made := made + 1; end if;
    end if;
    if o.stage = 'in_review' then
      ev := raise_obligation_event(o.id, 'approval_pending',
              'W' || ((today - (select max(t.at)::date from obligation_transitions t where t.obligation_id = o.id and t.to_stage = 'in_review')) / 7)::text,
              'normal', today, 1::smallint);
      if ev is not null then made := made + 1; end if;
    end if;
    if o.stage = 'executed' and days <= 0 then
      ev := raise_obligation_event(o.id, 'filing_confirmation_pending', 'FC' || (-days / 7)::text, 'high', today);
      if ev is not null then made := made + 1; end if;
    end if;
  end loop;

  update scheduler_runs set finished_at = now(), ok = true,
         detail = jsonb_build_object('events_created', made, 'already_sent', skipped, 'review_alerts', review)
   where id = run_id;
  return jsonb_build_object('events_created', made, 'already_sent', skipped, 'review_alerts', review);
end $$;

-- legacy daily job now delegates to the new generator
create or replace function run_daily_reminders(p_today date default current_date) returns int
language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  r := generate_notification_events(p_today);
  return coalesce((r->>'events_created')::int, 0);
end $$;
-- the old per-obligation reminders table is no longer maintained (kept for history)
drop trigger if exists t_obl_reminders on obligations;

-- Email worker API (service role only). Claims due email deliveries with row locks so parallel workers never double-send.
create or replace function claim_email_deliveries(p_limit int default 25)
returns table(delivery_id uuid, email text, recipient_name text, company text, compliance text, compliance_title text,
              due_date date, current_status text, priority text, trigger_type text, assigned_to text, required_action text,
              legal_reference text, verification_status text, obligation_id uuid, escalation_level smallint, attempts int)
language plpgsql security definer set search_path = public as $$
begin
  -- recover deliveries stuck in 'sending' (worker crashed mid-batch). The provider call uses the delivery id as an
  -- idempotency key, so a retry after an unseen success does not send a second email.
  update notification_deliveries set status = 'queued', last_error = 'recovered from interrupted send'
   where status = 'sending' and channel = 'email' and updated_at < now() - interval '15 minutes';
  -- suppress deliveries whose obligation was closed/cancelled after the event was raised
  update notification_deliveries d set status = 'suppressed', last_error = 'obligation no longer open'
    from notification_events e join obligations o on o.id = e.obligation_id
   where d.event_id = e.id and d.status = 'queued' and d.channel = 'email'
     and not obligation_open(o.stage) and e.trigger_type not in ('evidence_missing');

  return query
  with picked as (
    select d.id from notification_deliveries d
     where d.status = 'queued' and d.channel = 'email' and d.next_attempt_at <= now()
     order by d.next_attempt_at
     limit greatest(1, least(p_limit, 200))
     for update skip locked
  ), upd as (
    update notification_deliveries d set status = 'sending', attempts = d.attempts + 1
      from picked where d.id = picked.id
    returning d.*
  )
  select upd.id, upd.email_snapshot,
         coalesce(k.full_name, u.email),
         cl.name, ru.form, ru.title, o.due_date,
         o.stage::text, e.priority::text, e.trigger_type::text,
         (select au.email from auth.users au where au.id = o.assignee),
         trigger_action(e.trigger_type),
         case when e.verification_status = 'approved_rule'
              then nullif(concat_ws(' · ', v.authority, v.section_or_rule, v.source_document), '') end,
         e.verification_status, o.id, upd.escalation_level, upd.attempts
    from upd
    join notification_events e on e.id = upd.event_id
    join obligations o on o.id = e.obligation_id
    join clients cl on cl.id = o.client_id
    join rule_versions v on v.id = o.rule_version_id
    join rules ru on ru.id = v.rule_id
    left join client_contacts k on k.id = upd.recipient_contact_id
    left join auth.users u on u.id = upd.recipient_user_id;
end $$;

-- Record the provider's answer. Transient failure → retry with backoff; permanent or exhausted → failed + admin alert.
create or replace function record_email_result(p_delivery uuid, p_ok boolean, p_provider text, p_message_id text,
                                               p_error text default null, p_permanent boolean default false)
returns delivery_status language plpgsql security definer set search_path = public as $$
declare d notification_deliveries; s delivery_status;
begin
  select * into d from notification_deliveries where id = p_delivery for update;
  if not found then raise exception 'delivery not found'; end if;
  if d.status <> 'sending' then raise exception 'delivery is %, not sending', d.status; end if;
  if p_ok then
    s := 'accepted';
    update notification_deliveries set status = s, provider = p_provider, provider_message_id = p_message_id,
           sent_at = now(), last_error = null where id = d.id;
  elsif p_permanent or d.attempts >= d.max_attempts then
    s := 'failed';
    update notification_deliveries set status = s, provider = p_provider, last_error = left(p_error, 1000) where id = d.id;
    insert into notifications(org_id, user_id, category, title, body, event_id, priority)
    values (d.org_id, null, 'system_alert', 'Email reminder could not be delivered',
            format('Delivery to %s failed after %s attempt(s): %s', d.email_snapshot, d.attempts, left(coalesce(p_error,'unknown error'), 300)),
            d.event_id, 'high');
  else
    s := 'queued';
    update notification_deliveries set status = s, provider = p_provider, last_error = left(p_error, 1000),
           next_attempt_at = now() + make_interval(mins => (power(2, least(d.attempts, 8)))::int) where id = d.id;
  end if;
  return s;
end $$;

-- Provider webhook (delivered / bounced / complained). Only moves forward from accepted.
create or replace function record_provider_event(p_provider text, p_message_id text, p_event text, p_detail text default null)
returns boolean language plpgsql security definer set search_path = public as $$
declare d notification_deliveries;
begin
  select * into d from notification_deliveries where provider = p_provider and provider_message_id = p_message_id for update;
  if not found then return false; end if;
  if p_event = 'delivered' and d.status in ('accepted','sending') then
    update notification_deliveries set status = 'delivered', delivered_at = now() where id = d.id;
  elsif p_event in ('bounced','complained') and d.status in ('accepted','sending','delivered') then
    update notification_deliveries set status = 'bounced', last_error = coalesce(p_detail, p_event) where id = d.id;
    insert into notifications(org_id, category, title, body, event_id, priority)
    values (d.org_id, 'system_alert', 'Email reminder bounced', format('%s: %s', d.email_snapshot, coalesce(p_detail, p_event)), d.event_id, 'high');
  else
    return false;
  end if;
  return true;
end $$;

-- in-app: mark read (own or org-wide items)
create or replace function mark_notifications_read(p_ids uuid[] default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update notifications set read_at = now()
   where read_at is null and (p_ids is null or id = any(p_ids))
     and ((org_id is not null and is_org_member(org_id) and (user_id is null or user_id = auth.uid()))
          or (org_id is null and is_staff()));
  get diagnostics n = row_count;
  return n;
end $$;

-- member directory for recipient pickers: members of the same organisation only (no cross-tenant emails)
create or replace function org_member_directory(p_org uuid)
returns table(user_id uuid, email text, role member_role)
language sql stable security definer set search_path = public as $$
  select m.user_id, u.email::text, m.role from org_members m join auth.users u on u.id = m.user_id
   where m.org_id = p_org and is_org_member(p_org) order by u.email
$$;

-- platform health for staff: aggregate delivery status and scheduler runs; no recipient addresses are exposed
create or replace function delivery_health_summary(p_days int default 7)
returns table(channel text, status delivery_status, deliveries bigint, organisations bigint, last_error text)
language sql stable security definer set search_path = public as $$
  select d.channel, d.status, count(*), count(distinct d.org_id),
         (array_agg(regexp_replace(d.last_error, '[^@\s]+@[^@\s]+', '<address>', 'g') order by d.updated_at desc)
            filter (where d.last_error is not null))[1]
    from notification_deliveries d
   where d.created_at > now() - make_interval(days => least(greatest(p_days,1), 90)) and is_staff()
   group by d.channel, d.status order by d.channel, d.status
$$;

-- ════════════════════════════ 6. contact email verification ════════════════════════════
-- request: called ONLY by the server (edge function) on behalf of an org admin. The raw token is returned to the
-- server, emailed to the contact, and never shown to the admin (so an admin cannot self-verify an address).
create or replace function request_contact_verification(p_contact uuid, p_actor uuid)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare k client_contacts; tok text;
begin
  select * into k from client_contacts where id = p_contact for update;
  if not found or not exists (select 1 from org_members m where m.org_id = k.org_id and m.user_id = p_actor and m.role in ('owner','admin')) then
    raise exception 'only an organisation admin may verify contacts' using errcode = '42501';
  end if;
  if not k.active then raise exception 'contact is inactive'; end if;
  if k.verify_sent_at > now() - interval '2 minutes' then raise exception 'verification email already sent; wait a moment'; end if;
  tok := encode(gen_random_bytes(24), 'hex');
  perform set_config('regulenta.verifying', 'on', true);
  update client_contacts set verify_token_hash = encode(digest(tok, 'sha256'), 'hex'), verify_sent_at = now() where id = k.id;
  perform set_config('regulenta.verifying', 'off', true);
  insert into audit_log(org_id, user_id, action, entity, entity_id, detail)
  values (k.org_id, p_actor, 'verification_requested', 'client_contact', k.id, jsonb_build_object('email', k.email));
  return tok;
end $$;

-- confirm: anyone holding the token (link click), valid for 7 days
create or replace function confirm_contact_email(p_token text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare k client_contacts;
begin
  select * into k from client_contacts
   where verify_token_hash = encode(digest(p_token, 'sha256'), 'hex') and verify_sent_at > now() - interval '7 days' for update;
  if not found then return false; end if;
  perform set_config('regulenta.verifying', 'on', true);
  update client_contacts set email_verified_at = now(), verify_token_hash = null where id = k.id;
  perform set_config('regulenta.verifying', 'off', true);
  insert into audit_log(org_id, action, entity, entity_id, detail)
  values (k.org_id, 'email_verified', 'client_contact', k.id, jsonb_build_object('email', k.email));
  return true;
end $$;

-- ════════════════════════════ 7. regulatory intelligence ════════════════════════════
alter table regulatory_documents
  add column legal_status legal_status,
  add column commencement_on date,
  add column jurisdiction text,
  add column retrieval_status text not null default 'reference_only' check (retrieval_status in ('retrieved','failed','reference_only')),
  add column retrieval_error text;

alter table regulatory_changes
  add column title text,
  add column action change_action,
  add column legal_status legal_status,
  add column commencement_on date,
  add column impact_summary text,                       -- drafted text; shown with a DRAFT label until reviewed
  add column interpretation_required boolean not null default false,
  add column client_action text,
  add column affected_rule_ids uuid[] not null default '{}',
  add column reviewer uuid references auth.users(id),
  add column reviewed_at timestamptz,
  add column created_by uuid references auth.users(id);

create policy chg_admin on regulatory_changes for all
  using (has_platform_role(array['super_admin','admin','reviewer']::platform_role[]))
  with check (has_platform_role(array['super_admin','admin','reviewer']::platform_role[]));
create policy job_admin on monitoring_jobs for insert
  with check (has_platform_role(array['super_admin','admin']::platform_role[]));

-- Manual / semi-automated ingestion: one call records the document, the detected change and a research-queue item.
-- Nothing becomes a rule here; the queue item still needs evidence + human approval.
create or replace function log_regulatory_change(
  p_authority uuid, p_title text, p_doc_type text, p_official_url text, p_legal_status legal_status,
  p_change_type change_type, p_action change_action,
  p_doc_number text default null, p_published_on date default null, p_doc_date date default null,
  p_effective_on date default null, p_commencement_on date default null, p_jurisdiction text default null,
  p_affected_law text default null, p_affected_provision text default null,
  p_previous_requirement text default null, p_new_requirement text default null,
  p_affected_rule_ids uuid[] default '{}', p_source uuid default null, p_sha256 text default null,
  p_storage_path text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare d uuid; ch uuid; rid uuid;
begin
  if not has_platform_role(array['super_admin','admin','reviewer']::platform_role[]) then
    raise exception 'staff only' using errcode = '42501';
  end if;
  if coalesce(trim(p_title),'') = '' or coalesce(trim(p_official_url),'') = '' then
    raise exception 'title and official source URL are required';
  end if;
  insert into regulatory_documents(authority_id, source_id, title, doc_type, doc_number, official_url, published_on, effective_on,
                                   doc_date, storage_path, sha256, status, legal_status, commencement_on, jurisdiction, retrieval_status)
  values (p_authority, p_source, p_title, p_doc_type, p_doc_number, p_official_url, p_published_on, p_effective_on,
          p_doc_date, p_storage_path, p_sha256, 'unverified', p_legal_status, p_commencement_on, p_jurisdiction,
          case when p_storage_path is not null then 'retrieved' else 'reference_only' end)
  returning id into d;
  insert into regulatory_changes(authority_id, source_id, document_id, change_type, affected_law, affected_provision,
                                 published_on, effective_on, previous_requirement, new_requirement, status, title, action,
                                 legal_status, commencement_on, affected_rule_ids, created_by,
                                 interpretation_required)
  values (p_authority, p_source, d, p_change_type, p_affected_law, p_affected_provision, p_published_on, p_effective_on,
          p_previous_requirement, p_new_requirement, 'new', p_title, p_action, p_legal_status, p_commencement_on,
          coalesce(p_affected_rule_ids,'{}'), auth.uid(),
          p_legal_status in ('draft_proposal','official_guidance','informational'))
  returning id into ch;
  -- one queue item per affected rule (or one without a rule for a new obligation); draft law never queues
  if p_legal_status is distinct from 'draft_proposal' then
    if coalesce(cardinality(p_affected_rule_ids),0) = 0 then
      insert into research_queue(change_id, authority_id, document_id, change_type, previous_rule, proposed, effective_date, status, confidence)
      values (ch, p_authority, d, p_change_type, p_previous_requirement,
              jsonb_build_object('title', p_title, 'new_requirement', p_new_requirement), coalesce(p_commencement_on, p_effective_on), 'new', 'low');
    else
      foreach rid in array p_affected_rule_ids loop
        insert into research_queue(change_id, rule_id, authority_id, document_id, change_type, previous_rule, proposed, effective_date, status, confidence)
        values (ch, rid, p_authority, d, p_change_type, p_previous_requirement,
                jsonb_build_object('title', p_title, 'new_requirement', p_new_requirement), coalesce(p_commencement_on, p_effective_on), 'new', 'low');
      end loop;
    end if;
  end if;
  return ch;
end $$;

-- Impact report (staff): per change — affected rules, open obligations and companies. Read-only.
create or replace function change_impact(p_change uuid)
returns table(rule_id uuid, rule_key text, title text, active_version int, open_obligations bigint,
              companies bigint, organisations bigint, effective_on date, legal_status legal_status, action change_action,
              interpretation_required boolean, review_status research_status)
language sql stable security definer set search_path = public as $$
  select r.id, r.rule_key, r.title,
         (select v.version from rule_versions v where v.rule_id = r.id and v.state = 'active'),
         count(o.id) filter (where obligation_open(o.stage) and o.lifecycle = 'active'),
         count(distinct o.client_id) filter (where obligation_open(o.stage)),
         count(distinct o.org_id) filter (where obligation_open(o.stage)),
         ch.effective_on, ch.legal_status, ch.action, ch.interpretation_required, ch.status
    from regulatory_changes ch
    cross join lateral unnest(ch.affected_rule_ids) as ar(id)
    join rules r on r.id = ar.id
    left join rule_versions v on v.rule_id = r.id
    left join obligations o on o.rule_version_id = v.id
   where ch.id = p_change and is_staff()
   group by r.id, r.rule_key, r.title, ch.effective_on, ch.legal_status, ch.action, ch.interpretation_required, ch.status
$$;

-- When a reviewer approves a change's rule version, the existing approve_rule_change() notifies affected clients
-- (recalc_after_rule_change). Detected-but-unreviewed changes never reach clients.

-- ════════════════════════════ 8. org-scoped audit + RLS for new tables ════════════════════════════
create or replace function audit_org_row() returns trigger language plpgsql security definer set search_path = public as $$
declare r jsonb := to_jsonb(coalesce(new, old));
begin
  insert into audit_log(org_id, user_id, action, entity, entity_id, detail)
  values ((r->>'org_id')::uuid, auth.uid(), lower(tg_op), tg_table_name, (r->>'id')::uuid,
          jsonb_build_object('old', case when tg_op <> 'INSERT' then to_jsonb(old) - 'verify_token_hash' end,
                             'new', case when tg_op <> 'DELETE' then to_jsonb(new) - 'verify_token_hash' end));
  return coalesce(new, old);
end $$;
create trigger t_audit_contacts   after insert or update or delete on client_contacts        for each row execute function audit_org_row();
create trigger t_audit_recipients after insert or update or delete on notification_recipients for each row execute function audit_org_row();
create trigger t_audit_remset     after insert or update or delete on reminder_settings      for each row execute function audit_org_row();
create trigger t_audit_clients    after insert or update on clients                           for each row execute function audit_org_row();
create trigger t_audit_docs_org   after insert or delete on documents                         for each row execute function audit_org_row();

alter table client_contacts          enable row level security;
alter table notification_recipients  enable row level security;
alter table obligation_transitions   enable row level security;
alter table notification_events      enable row level security;
alter table notification_deliveries  enable row level security;
alter table escalation_history       enable row level security;
alter table scheduler_runs           enable row level security;

create policy cc_select on client_contacts for select using (is_org_member(org_id));
create policy cc_write  on client_contacts for all using (is_org_admin(org_id)) with check (is_org_admin(org_id));
create policy nr_select on notification_recipients for select using (is_org_member(org_id));
create policy nr_write  on notification_recipients for all using (is_org_admin(org_id)) with check (is_org_admin(org_id));
create policy ot_select on obligation_transitions for select using (is_org_member(org_id));
create policy ne_select on notification_events for select using ((org_id is not null and is_org_member(org_id)) or (org_id is null and is_staff()));
create policy nd_select on notification_deliveries for select using (
  (org_id is not null and (is_org_admin(org_id) or recipient_user_id = auth.uid())) or (org_id is null and is_staff()));
create policy eh_select on escalation_history for select using (org_id is not null and is_org_admin(org_id));
create policy sr_select on scheduler_runs for select using (is_staff());
create policy audit_org_admin on audit_log for select using (org_id is not null and is_org_admin(org_id));

-- ════════════════════════════ 9. grants / security tightening ════════════════════════════
-- No anonymous access to any function in public except email confirmation.
revoke execute on all functions in schema public from public, anon;
grant execute on function confirm_contact_email(text) to anon, authenticated;

-- service-role only (scheduler + email worker)
revoke execute on function generate_notification_events(date) from authenticated;
revoke execute on function run_daily_reminders(date) from authenticated;
revoke execute on function raise_obligation_event(uuid, notif_trigger, text, notif_priority, date, smallint) from authenticated;
revoke execute on function claim_email_deliveries(int) from authenticated;
revoke execute on function record_email_result(uuid, boolean, text, text, text, boolean) from authenticated;
revoke execute on function record_provider_event(text, text, text, text) from authenticated;
revoke execute on function request_contact_verification(uuid, uuid) from authenticated;
grant execute on function generate_notification_events(date), run_daily_reminders(date),
  raise_obligation_event(uuid, notif_trigger, text, notif_priority, date, smallint), claim_email_deliveries(int),
  record_email_result(uuid, boolean, text, text, text, boolean), record_provider_event(text, text, text, text),
  request_contact_verification(uuid, uuid), activate_scheduled_rule_versions(date)
  to service_role;

-- signed-in users (each function checks org membership / role itself)
grant execute on function transition_obligation(uuid, obligation_stage, text, text), set_obligation_requirements(uuid, boolean, boolean, text),
  extend_obligation(uuid, date, text, uuid), preview_obligations(uuid, date, date), generate_obligations(uuid, date, date),
  activate_obligations(uuid, uuid[]), discard_proposed_obligations(uuid, uuid[]), create_event_obligation(uuid, text, date, text),
  mark_notifications_read(uuid[]), log_regulatory_change(uuid, text, text, text, legal_status,
  change_type, change_action, text, date, date, date, date, text, text, text, text, text, uuid[], uuid, text, text),
  change_impact(uuid), evaluate_applicability(uuid, uuid), org_member_directory(uuid), delivery_health_summary(int)
  to authenticated;
-- helpers used inside RLS policies must stay executable by authenticated
grant execute on function is_org_member(uuid), can_write_org(uuid), is_org_admin(uuid), is_staff(),
  has_platform_role(platform_role[]), create_org(text, org_type), approve_rule_change(uuid, text),
  reject_rule_change(uuid, text, boolean), rule_impact(uuid), stage_to_status(obligation_stage), obligation_open(obligation_stage),
  is_non_working(date), rule_version_verified(uuid, date), trigger_category(notif_trigger), trigger_action(notif_trigger)
  to authenticated;

-- table privileges for the new tables follow Supabase defaults (RLS decides). Internal-only tables get none for clients:
revoke all on scheduler_runs from anon;
revoke insert, update, delete on notification_events, notification_deliveries, escalation_history, obligation_transitions, scheduler_runs
  from anon, authenticated;

commit;
