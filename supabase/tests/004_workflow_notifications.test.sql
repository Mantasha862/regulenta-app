-- REGULENTA — tests for migration 004. Run on a DISPOSABLE local database only (creates test users and data).
-- psql -v ON_ERROR_STOP=1 -f 004_workflow_notifications.test.sql ; ends with a PASS/FAIL summary and exits non-zero on failure.
\set ON_ERROR_STOP on
\pset footer off

-- ───────── harness ─────────
create schema tests;
create table tests.results(id serial primary key, name text not null, ok boolean not null, detail text);
grant usage on schema tests to public;
grant all on tests.results to public;
grant usage on sequence tests.results_id_seq to public;
create function tests.check(p_ok boolean, p_name text, p_detail text default null) returns void language sql as
  $$ insert into tests.results(name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail) $$;
-- run SQL as the CURRENT role; pass if it raises an error matching the pattern
create function tests.expect_error(p_sql text, p_name text, p_pattern text default '') returns void language plpgsql as $$
begin
  begin
    execute p_sql;
    insert into tests.results(name, ok, detail) values (p_name, false, 'no error raised');
  exception when others then
    insert into tests.results(name, ok, detail) values (p_name, sqlerrm ilike '%' || p_pattern || '%', sqlerrm);
  end;
end $$;
grant execute on all functions in schema tests to public;

-- ───────── fixtures (as superuser) ─────────
insert into auth.users(id, email) values
 ('a1000000-0000-0000-0000-000000000001','owner@firma.test'),
 ('a2000000-0000-0000-0000-000000000002','member@firma.test'),
 ('a3000000-0000-0000-0000-000000000003','admin2@firma.test'),
 ('b1000000-0000-0000-0000-000000000001','owner@firmb.test'),
 ('99999999-0000-0000-0000-000000000009','reviewer@platform.test');
insert into platform_roles values ('99999999-0000-0000-0000-000000000009','reviewer');
insert into regulatory_authorities(id, code, name) values ('d0000000-0000-0000-0000-00000000000d','TEST','Test Authority (fixture)');
insert into regulatory_documents(id, authority_id, title, doc_type, official_url, status)
values ('dd000000-0000-0000-0000-0000000000dd','d0000000-0000-0000-0000-00000000000d','FIXTURE DOCUMENT — not real law','notification','https://example.invalid/fixture','current');

-- research queue items with canonical schedules (FIXTURE rules, not real compliance)
insert into research_queue(id, proposed, evidence, confidence, effective_date) values
 ('e1000000-0000-0000-0000-000000000001',
  '{"rule_key":"FX-MONTHLY","law":"OTHER","form":"FX-M","title":"Fixture monthly return","kind":"recurring","schedule":{"type":"monthly_day","day":20},"due_text":"20th of next month","applies_when":{}}',
  '[{"document_id":"dd000000-0000-0000-0000-0000000000dd","passage":"fixture passage","page":1}]','high','2026-01-01'),
 ('e2000000-0000-0000-0000-000000000002',
  '{"rule_key":"FX-QTR","law":"OTHER","form":"FX-Q","title":"Fixture quarterly statement","kind":"recurring","schedule":{"type":"after_period_end","period":"quarter","days":21,"day_type":"calendar"},"due_text":"21 days after quarter end","applies_when":{}}',
  '[{"document_id":"dd000000-0000-0000-0000-0000000000dd","passage":"fixture passage","page":2}]','high','2026-01-01'),
 ('e3000000-0000-0000-0000-000000000003',
  '{"rule_key":"FX-EVENT","law":"OTHER","form":"FX-E","title":"Fixture post-AGM filing","kind":"event","schedule":{"type":"event_offset","anchor":"AGM","days":30,"day_type":"calendar","direction":1},"due_text":"30 days after AGM","applies_when":{}}',
  '[{"document_id":"dd000000-0000-0000-0000-0000000000dd","passage":"fixture passage","page":3}]','high','2026-01-01'),
 ('e4000000-0000-0000-0000-000000000004',
  '{"rule_key":"FX-LISTED","law":"OTHER","form":"FX-L","title":"Fixture listed-only annual item","kind":"fixed","schedule":{"type":"annual_fixed","day":30,"month":5},"due_text":"30 May","applies_when":{"listed":true}}',
  '[{"document_id":"dd000000-0000-0000-0000-0000000000dd","passage":"fixture passage","page":4}]','high','2026-01-01'),
 ('e5000000-0000-0000-0000-000000000005',
  '{"rule_key":"FX-NOEVIDENCE","law":"OTHER","form":"FX-N","title":"Fixture without evidence","kind":"fixed","schedule":{"type":"annual_fixed","day":1,"month":1},"due_text":"1 Jan","applies_when":{}}',
  '[]','low','2026-01-01'),
 ('e6000000-0000-0000-0000-000000000006',
  '{"rule_key":"FX-LEGACY","law":"OTHER","form":"FX-X","title":"Fixture non-canonical schedule","kind":"fixed","schedule":{"varies":true},"due_text":"varies","applies_when":{}}',
  '[{"document_id":"dd000000-0000-0000-0000-0000000000dd","passage":"fixture passage","page":5}]','low','2026-01-01');

-- ───────── 1. rule approval (reviewer) ─────────
set role authenticated;
set request.jwt.claim.sub = 'a1000000-0000-0000-0000-000000000001';
select tests.expect_error($$select approve_rule_change('e1000000-0000-0000-0000-000000000001','x')$$, '01 non-reviewer cannot approve a rule', 'only reviewers');
set request.jwt.claim.sub = '99999999-0000-0000-0000-000000000009';
select approve_rule_change(id, 'fixture approval') from research_queue where id in
  ('e1000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000002','e3000000-0000-0000-0000-000000000003',
   'e4000000-0000-0000-0000-000000000004','e6000000-0000-0000-0000-000000000006') order by id;
select tests.expect_error($$select approve_rule_change('e5000000-0000-0000-0000-000000000005','x')$$, '02 rule without evidence cannot be approved', 'without evidence');
reset role;
select tests.check((select count(*) from rule_versions where state = 'active') = 5, '03 five fixture rules active after approval');

-- ───────── 2. tenants, companies, members ─────────
set role authenticated;
set request.jwt.claim.sub = 'a1000000-0000-0000-0000-000000000001';
select create_org('Firm A (test)','firm') as org_a \gset
insert into org_members(org_id, user_id, role) values
  (:'org_a','a2000000-0000-0000-0000-000000000002','member'),
  (:'org_a','a3000000-0000-0000-0000-000000000003','admin');
insert into clients(org_id, name, entity_type, fy_end_month) values (:'org_a','Kestrel Foods Pvt Ltd (test)','Private Limited Company',3) returning id as cl_a \gset
select tests.expect_error(format($$insert into clients(org_id,name,entity_type,cin_or_llpin) values (%L,'Bad CIN','Private Limited Company','ABC123')$$, :'org_a'),
  '04 invalid CIN/LLPIN format rejected', 'clients_cin_format');
insert into clients(org_id, name, entity_type, cin_or_llpin) values (:'org_a','Valid CIN Co (test)','Private Limited Company','U74999HR2015PTC012345');
select tests.check(true, '05 valid CIN accepted');
set request.jwt.claim.sub = 'b1000000-0000-0000-0000-000000000001';
select create_org('Firm B (test)','firm') as org_b \gset
insert into clients(org_id, name, entity_type) values (:'org_b','Bravo Ltd (test)','Private Limited Company') returning id as cl_b \gset

-- ───────── 3. deadline engine ─────────
set request.jwt.claim.sub = 'a1000000-0000-0000-0000-000000000001';
select tests.expect_error(format($$insert into obligations(org_id,client_id,rule_version_id,period_label,due_date) select %L,%L,id,'X','2026-12-01' from rule_versions limit 1$$, :'org_a', :'cl_a'),
  '06 direct insert of an obligation is blocked', 'deadline engine');
create temp table pv as select * from preview_obligations(:'cl_a', '2026-10-01', '2027-01-31');
select tests.check((select count(*) from pv where rule_key = 'FX-MONTHLY' and action = 'create') = 4, '07 monthly_day previews 4 due dates (Oct–Jan)',
  (select string_agg(due_date::text, ',' order by due_date) from pv where rule_key = 'FX-MONTHLY'));
select tests.check((select string_agg(due_date::text, ',' order by due_date) from pv where rule_key = 'FX-QTR' and action = 'create') = '2026-10-21,2027-01-21',
  '08 after_period_end quarter + 21 days', (select string_agg(due_date::text, ',' order by due_date) from pv where rule_key = 'FX-QTR'));
select tests.check(exists (select 1 from pv where rule_key = 'FX-LISTED' and action = 'review_required'), '09 missing profile fact → review_required, not guessed');
select tests.check(exists (select 1 from pv where rule_key = 'FX-LEGACY' and action = 'skip' and reason ilike '%non-canonical%'), '10 non-canonical schedule skipped with reason');
select tests.check(exists (select 1 from pv where rule_key = 'FX-EVENT' and action = 'skip'), '11 event rule not generated by date window');
select tests.check((select non_working_day from pv where rule_key = 'FX-MONTHLY' and due_date = '2026-12-20') and
                   not exists (select 1 from pv where rule_key = 'FX-MONTHLY' and due_date = '2026-12-21'),
  '12 Sunday due date flagged, not moved');
select generate_obligations(:'cl_a', '2026-10-01', '2027-01-31') as made \gset
select tests.check(:made = 6, '13 generate creates 6 proposed obligations', :'made');
select tests.check(generate_obligations(:'cl_a', '2026-10-01', '2027-01-31') = 0, '14 re-running generate is idempotent');
select tests.check((select bool_and(lifecycle = 'proposed') from obligations where client_id = :'cl_a'), '15 generated obligations start as proposed');
set request.jwt.claim.sub = 'b1000000-0000-0000-0000-000000000001';
select tests.expect_error(format($$select * from preview_obligations(%L)$$, :'cl_a'), '16 other firm cannot preview my company', 'not accessible');
select tests.check((select count(*) from obligations where client_id = :'cl_a') = 0, '17 other firm sees none of my obligations (RLS)');
set request.jwt.claim.sub = 'a2000000-0000-0000-0000-000000000002';
select tests.expect_error(format($$select activate_obligations(%L)$$, :'cl_a'), '18 member (non-admin) cannot activate deadlines', 'only an organisation admin');
set request.jwt.claim.sub = 'a1000000-0000-0000-0000-000000000001';
select tests.check(activate_obligations(:'cl_a') = 6, '19 admin activates proposed obligations');
select create_event_obligation(:'cl_a', 'FX-EVENT', '2026-09-30', 'AGM held') as ev_ob \gset
select tests.check((select due_date = '2026-10-30' and lifecycle = 'proposed' from obligations where id = :'ev_ob'), '20 event obligation: AGM + 30 days, proposed');
select activate_obligations(:'cl_a', array[:'ev_ob']::uuid[]);

select id as ob_oct from obligations where client_id = :'cl_a' and period_label = 'Sep 2026' \gset
select id as ob_nov from obligations where client_id = :'cl_a' and period_label = 'Oct 2026' \gset
select id as ob_q   from obligations where client_id = :'cl_a' and due_date = '2026-10-21' \gset

-- ───────── 4. workflow guard + transitions ─────────
select tests.expect_error(format($$update obligations set status = 'filed' where id = %L$$, :'ob_nov'), '21 direct status change blocked', 'transition_obligation');
select tests.expect_error(format($$update obligations set due_date = '2027-03-01' where id = %L$$, :'ob_nov'), '22 direct due-date change blocked', 'extend_obligation');
update obligations set notes = 'internal note', assignee = 'a2000000-0000-0000-0000-000000000002' where id = :'ob_oct';
select tests.check((select notes = 'internal note' from obligations where id = :'ob_oct'), '23 notes/assignee editable directly');

set request.jwt.claim.sub = 'a2000000-0000-0000-0000-000000000002';
select transition_obligation(:'ob_nov', 'preparing');
select transition_obligation(:'ob_nov', 'in_review', 'draft ready');
select tests.expect_error(format($$select transition_obligation(%L,'approved')$$, :'ob_nov'), '24 member cannot approve', 'only an organisation admin');
set request.jwt.claim.sub = 'a1000000-0000-0000-0000-000000000001';
select transition_obligation(:'ob_nov', 'approved', 'checked');
select tests.expect_error(format($$select transition_obligation(%L,'filed')$$, :'ob_nov'), '25 filing without acknowledgement reference blocked', 'reference');
select transition_obligation(:'ob_nov', 'filed', null, 'SRN-TEST-0001');
select tests.expect_error(format($$select transition_obligation(%L,'closed')$$, :'ob_nov'), '26 closing without evidence blocked', 'evidence');
insert into documents(org_id, client_id, obligation_id, storage_path, file_name) values (:'org_a', :'cl_a', :'ob_nov', :'org_a' || '/test/ack.pdf', 'ack.pdf');
select transition_obligation(:'ob_nov', 'closed', 'acknowledgement uploaded');
select tests.check((select stage = 'closed' and status = 'filed' and reference_no = 'SRN-TEST-0001' from obligations where id = :'ob_nov'), '27 closed after review, filing and evidence');
select tests.expect_error(format($$select transition_obligation(%L,'preparing')$$, :'ob_nov'), '28 reopening needs a reason', 'reason');

-- maker-checker: the person who submits for review cannot approve
select transition_obligation(:'ob_q', 'preparing');
select transition_obligation(:'ob_q', 'in_review');
select tests.expect_error(format($$select transition_obligation(%L,'approved')$$, :'ob_q'), '29 maker-checker: submitter cannot approve', 'maker-checker');
set request.jwt.claim.sub = 'a3000000-0000-0000-0000-000000000003';
select transition_obligation(:'ob_q', 'approved');
select tests.check(true, '30 a different admin can approve');
set request.jwt.claim.sub = 'a2000000-0000-0000-0000-000000000002';
select tests.expect_error(format($$select transition_obligation(%L,'cancelled','x')$$, :'ob_q'), '31 member cannot cancel', 'only an organisation admin');
select tests.expect_error(format($$select transition_obligation(%L,'closed')$$, :'ob_oct'), '32 illegal transition rejected', 'not allowed');
reset role;

-- ───────── 5. recipients + contacts ─────────
set role authenticated;
set request.jwt.claim.sub = 'a1000000-0000-0000-0000-000000000001';
insert into reminder_settings(org_id, email_enabled) values (:'org_a', true);
insert into client_contacts(org_id, client_id, full_name, email, role, notify_email) values
  (:'org_a', :'cl_a', 'Officer Test', 'officer@kestrel.test', 'compliance_officer', true),
  (:'org_a', :'cl_a', 'Manager Test', 'manager@kestrel.test', 'management', true),
  (:'org_a', :'cl_a', 'Director Not Authorised', 'director@kestrel.test', 'other', false);
select id as k_off from client_contacts where email = 'officer@kestrel.test' \gset
select id as k_mgr from client_contacts where email = 'manager@kestrel.test' \gset
select tests.check((select email_verified_at is null from client_contacts where id = :'k_off'), '33 new contact starts unverified');
select tests.expect_error(format($$update client_contacts set email_verified_at = now() where id = %L$$, :'k_off'), '34 verification cannot be faked by direct update', 'confirm_contact_email');
insert into notification_recipients(org_id, client_id, user_id, escalation_level) values (:'org_a', :'cl_a', 'a2000000-0000-0000-0000-000000000002', 0);
insert into notification_recipients(org_id, client_id, contact_id, escalation_level) values (:'org_a', :'cl_a', :'k_off', 1), (:'org_a', :'cl_a', :'k_mgr', 2);
select tests.expect_error(format($$insert into notification_recipients(org_id, user_id) values (%L,'b1000000-0000-0000-0000-000000000001')$$, :'org_a'),
  '35 non-member cannot be made a recipient', 'not a member');
set request.jwt.claim.sub = 'a2000000-0000-0000-0000-000000000002';
select tests.expect_error(format($$insert into notification_recipients(org_id, user_id) values (%L,'a2000000-0000-0000-0000-000000000002')$$, :'org_a'),
  '36 member (non-admin) cannot configure recipients', 'row-level security');
set request.jwt.claim.sub = 'b1000000-0000-0000-0000-000000000001';
select tests.expect_error(format($$insert into client_contacts(org_id, client_id, full_name, email) values (%L,%L,'x','x@x.test')$$, :'org_a', :'cl_a'),
  '37 other firm cannot add contacts to my company', '');
reset role;

-- ───────── 6. reminder scheduler ─────────
-- permissions first
set role authenticated;
set request.jwt.claim.sub = 'a1000000-0000-0000-0000-000000000001';
select tests.expect_error($$select generate_notification_events('2026-09-20')$$, '38 signed-in users cannot run the scheduler', 'permission denied');
select tests.expect_error($$select * from claim_email_deliveries(5)$$, '39 signed-in users cannot claim emails', 'permission denied');
reset role;
set role anon;
select tests.expect_error(format($$select transition_obligation(%L,'preparing')$$, :'ob_oct'), '40 anonymous cannot call workflow functions', 'permission denied');
reset role;

set role service_role;
select generate_notification_events('2026-09-20');   -- ob_oct due 2026-10-20 → D-30
reset role;
select tests.check((select count(*) from notification_events where obligation_id = :'ob_oct' and stage_key = 'D-30' and trigger_type = 'upcoming') = 1, '41 D-30 upcoming event created');
select tests.check((select count(*) from notification_deliveries d join notification_events e on e.id = d.event_id
                     where e.obligation_id = :'ob_oct' and e.stage_key = 'D-30' and d.channel = 'email' and d.email_snapshot = 'member@firma.test' and d.status = 'queued') = 1,
  '42 email queued for the configured member (also the assignee, once)');
select tests.check((select count(*) from notification_deliveries d join notification_events e on e.id = d.event_id
                     where e.obligation_id = :'ob_oct' and e.stage_key = 'D-30' and d.recipient_contact_id is not null) = 0,
  '43 level-1/2 contacts not sent first-stage reminders');
select tests.check((select count(*) from notification_events where obligation_id = :'ob_nov') = 0, '44 closed obligation gets no reminders');
set role service_role;
select generate_notification_events('2026-09-20');
reset role;
select tests.check((select count(*) from notification_events where obligation_id = :'ob_oct') = 1, '45 re-running the scheduler creates no duplicates');

set role service_role;
select generate_notification_events('2026-10-08');   -- 12 days before: threshold 15 (catch-up)
select generate_notification_events('2026-10-20');   -- due today
select generate_notification_events('2026-10-21');   -- 1 day overdue
select generate_notification_events('2026-10-23');   -- 3 days overdue
select generate_notification_events('2026-10-27');   -- 7 days overdue → escalation level 1
reset role;
select tests.check((select string_agg(stage_key, ',' order by created_at) from notification_events where obligation_id = :'ob_oct' and trigger_type <> 'not_started')
                   = 'D-30,D-15,D0,O+1,O+3,O+7', '46 reminder stages in order', (select string_agg(stage_key||':'||trigger_type, ',' order by created_at) from notification_events where obligation_id = :'ob_oct'));
select tests.check((select trigger_type = 'escalation' and escalation_level = 1 and priority = 'critical' from notification_events where obligation_id = :'ob_oct' and stage_key = 'O+7'),
  '47 7 days overdue → escalation, level 1, critical');
select tests.check((select count(*) from notification_deliveries d join notification_events e on e.id = d.event_id
                     where e.obligation_id = :'ob_oct' and e.stage_key = 'O+7' and d.recipient_contact_id = :'k_off') = 0,
  '48 unverified external contact receives nothing even when escalated');
select tests.check((select count(*) from escalation_history h join notification_events e on e.id = h.event_id where e.obligation_id = :'ob_oct') = 1, '49 escalation recorded in history');

-- verify the officer and manager contacts through the token flow
set role authenticated;
set request.jwt.claim.sub = 'a1000000-0000-0000-0000-000000000001';
select tests.expect_error(format($$select request_contact_verification(%L,'a1000000-0000-0000-0000-000000000001')$$, :'k_off'),
  '49a admins cannot obtain verification tokens directly (server only)', 'permission denied');
reset role;
set role service_role;
select tests.expect_error(format($$select request_contact_verification(%L,'a2000000-0000-0000-0000-000000000002')$$, :'k_off'),
  '49b server refuses verification requested by a non-admin', 'only an organisation admin');
select request_contact_verification(:'k_off', 'a1000000-0000-0000-0000-000000000001') as tok_off \gset
select request_contact_verification(:'k_mgr', 'a1000000-0000-0000-0000-000000000001') as tok_mgr \gset
reset role;
set role anon;
set request.jwt.claim.sub = '';
select tests.check(confirm_contact_email(:'tok_off'), '50 contact confirms email with token');
select tests.check(not confirm_contact_email('not-a-real-token'), '51 wrong token rejected');
select confirm_contact_email(:'tok_mgr');
reset role;

set role service_role;
select generate_notification_events('2026-11-03');   -- 14 days overdue → repeat at level 2
reset role;
select tests.check((select trigger_type = 'overdue_repeat' and escalation_level = 2 from notification_events where obligation_id = :'ob_oct' and stage_key = 'O+14'),
  '52 14 days overdue → continued reminder at level 2');
select tests.check((select count(distinct d.email_snapshot) from notification_deliveries d join notification_events e on e.id = d.event_id
                     where e.obligation_id = :'ob_oct' and e.stage_key = 'O+14' and d.channel = 'email') = 3,
  '53 level-2 event emails owner + verified officer + verified manager',
  (select string_agg(d.email_snapshot, ',') from notification_deliveries d join notification_events e on e.id = d.event_id where e.obligation_id = :'ob_oct' and e.stage_key = 'O+14' and d.channel = 'email'));
select tests.check((select count(*) from notification_deliveries where email_snapshot = 'director@kestrel.test') = 0, '54 contact listed in records but not authorised never emailed');

-- ───────── 7. deadline revision ─────────
set role authenticated;
set request.jwt.claim.sub = 'a1000000-0000-0000-0000-000000000001';
select id as ob_dec from obligations where client_id = :'cl_a' and period_label = 'Nov 2026' \gset
select tests.expect_error(format($$select extend_obligation(%L,'2026-12-31','')$$, :'ob_dec'), '55 extension needs a reason', 'reason');
select extend_obligation(:'ob_dec', '2026-12-31', 'Extension by circular (fixture)');
select tests.check((select count(*) from due_date_calculations where obligation_id = :'ob_dec' and kind = 'extension' and previous_due_date = '2026-12-20') = 1,
  '56 extension recorded with previous date and reason');
reset role;
set role service_role;
select generate_notification_events('2026-11-20');   -- before extension: 30 days ahead of 12-20; after: 41 days → no stage
select generate_notification_events('2026-12-01');   -- 30 days before revised date
reset role;
select tests.check((select string_agg(stage_key||'@'||due_date_snapshot, ',') from notification_events where obligation_id = :'ob_dec' and trigger_type = 'upcoming') = 'D-30@2026-12-31',
  '57 reminders follow the revised deadline', (select string_agg(stage_key||'@'||due_date_snapshot, ',') from notification_events where obligation_id = :'ob_dec'));

-- ───────── 8. unverified rule gate ─────────
delete from rule_evidence where rule_version_id = (select rule_version_id from obligations where id = :'ob_q');
set role service_role;
select generate_notification_events('2026-10-25');
reset role;
select tests.check((select count(*) from notification_events where obligation_id = :'ob_q' and trigger_type = 'review_required' and org_id is null) = 1,
  '58 unverified rule → staff review alert only');
select tests.check((select count(*) from notification_events where obligation_id = :'ob_q' and trigger_type <> 'review_required' and event_date = '2026-10-25') = 0,
  '59 unverified rule → no client deadline reminder (from the moment evidence is missing)');
set role authenticated;
set request.jwt.claim.sub = 'a1000000-0000-0000-0000-000000000001';
select tests.check((select count(*) from notifications where category = 'review_required') = 0, '60 client cannot see staff review alerts');
set request.jwt.claim.sub = '99999999-0000-0000-0000-000000000009';
select tests.check((select count(*) from notifications where category = 'review_required') >= 1, '61 platform reviewer sees the review alert');
reset role;

-- ───────── 9. completion / cancellation stop reminders ─────────
set role authenticated;
set request.jwt.claim.sub = 'a1000000-0000-0000-0000-000000000001';
select id as ob_jan from obligations where client_id = :'cl_a' and period_label = 'Dec 2026' \gset
select transition_obligation(:'ob_jan', 'cancelled', 'Company exempt (fixture)');
reset role;
set role service_role;
select generate_notification_events('2027-01-25');
reset role;
select tests.check((select count(*) from notification_events where obligation_id = :'ob_jan') = 0, '62 cancelled obligation gets no reminders');

-- reopen a closed item → reminders resume, reopen event recorded
set role authenticated;
set request.jwt.claim.sub = 'a1000000-0000-0000-0000-000000000001';
select transition_obligation(:'ob_nov', 'preparing', 'Revised filing needed (fixture)');
reset role;
select tests.check((select count(*) from notification_events where obligation_id = :'ob_nov' and trigger_type = 'reopened') = 1, '63 reopening records a reopened event');
set role service_role;
select generate_notification_events('2026-11-25');   -- ob_nov due 2026-11-20 → 5 days overdue
reset role;
select tests.check((select count(*) from notification_events where obligation_id = :'ob_nov' and trigger_type in ('overdue','overdue_followup')) = 1, '64 reopened item resumes overdue reminders');

-- ───────── 10. email worker API ─────────
set role service_role;
create temp table batch1 as select * from claim_email_deliveries(100);
create temp table batch2 as select * from claim_email_deliveries(100);
reset role;
select tests.check((select count(*) from batch1) > 0 and (select count(*) from batch2) = 0, '65 claimed emails are not handed out twice',
  (select count(*) from batch1)::text);
select tests.check((select bool_and(email is not null and company is not null and required_action is not null) from batch1), '66 claim returns full template data');
select tests.check((select bool_and(legal_reference is null or verification_status = 'approved_rule') from batch1), '67 legal reference only for verified rules');
select delivery_id as d1 from batch1 where obligation_id = :'ob_oct' order by delivery_id limit 1 offset 0 \gset
select delivery_id as d2 from batch1 where obligation_id = :'ob_oct' order by delivery_id limit 1 offset 1 \gset
select delivery_id as d3 from batch1 where obligation_id = :'ob_oct' order by delivery_id limit 1 offset 2 \gset
set role service_role;
select record_email_result(:'d1', true, 'resend', 'msg-test-1');
select record_email_result(:'d2', false, 'resend', null, 'timeout (fixture)');
select record_email_result(:'d3', false, 'resend', null, 'invalid recipient (fixture)', true);
select record_provider_event('resend', 'msg-test-1', 'delivered');
reset role;
select tests.check((select status = 'delivered' and sent_at is not null and delivered_at is not null from notification_deliveries where id = :'d1'), '68 accepted → delivered via provider event');
select tests.check((select status = 'queued' and next_attempt_at > now() and attempts = 1 from notification_deliveries where id = :'d2'), '69 transient failure → re-queued with backoff');
select tests.check((select status = 'failed' from notification_deliveries where id = :'d3'), '70 permanent failure → failed');
select tests.check((select count(*) from notifications where category = 'system_alert' and title ilike '%could not be delivered%') = 1, '71 failed delivery raises an admin alert');
select tests.check((select count(*) from notification_deliveries where status = 'delivered' and channel = 'email' and provider_message_id is null) = 0,
  '72 no email marked delivered without a provider confirmation');

-- suppression of queued email when obligation closed after the event
set role authenticated;
set request.jwt.claim.sub = 'a1000000-0000-0000-0000-000000000001';
select transition_obligation(:'ob_oct', 'cancelled', 'Filed outside the system (fixture)');
reset role;
update notification_deliveries set next_attempt_at = now() - interval '1 minute' where id = :'d2';
set role service_role;
create temp table batch3 as select * from claim_email_deliveries(100);
reset role;
select tests.check((select status = 'suppressed' from notification_deliveries where id = :'d2'), '73 queued email suppressed after the obligation was cancelled');

-- ───────── 11. org email switch ─────────
set role authenticated;
set request.jwt.claim.sub = 'b1000000-0000-0000-0000-000000000001';
reset role;
-- firm B: approve nothing new; generate + activate with email off (no reminder_settings row → email disabled)
set role authenticated;
set request.jwt.claim.sub = 'b1000000-0000-0000-0000-000000000001';
select generate_obligations(:'cl_b', '2026-10-01', '2026-11-30');
select activate_obligations(:'cl_b');
insert into notification_recipients(org_id, user_id) values (:'org_b', 'b1000000-0000-0000-0000-000000000001');
reset role;
set role service_role;
select generate_notification_events('2026-10-20');
reset role;
select tests.check((select count(*) from notification_deliveries where org_id = :'org_b' and channel = 'email' and status = 'queued') = 0
               and (select count(*) from notification_deliveries where org_id = :'org_b' and channel = 'email' and status = 'suppressed') >= 1,
  '74 email not queued until the organisation switches email on');

-- ───────── 12. tenant isolation of notification data ─────────
set role authenticated;
set request.jwt.claim.sub = 'b1000000-0000-0000-0000-000000000001';
select tests.check((select count(*) from notification_events where org_id = :'org_a') = 0
               and (select count(*) from notification_deliveries where org_id = :'org_a') = 0
               and (select count(*) from notifications where org_id = :'org_a') = 0
               and (select count(*) from client_contacts where org_id = :'org_a') = 0
               and (select count(*) from obligation_transitions where org_id = :'org_a') = 0,
  '75 other firm sees none of my notifications, deliveries, contacts or history');
set request.jwt.claim.sub = 'a2000000-0000-0000-0000-000000000002';
select tests.check((select count(*) from notification_deliveries where recipient_user_id is distinct from 'a2000000-0000-0000-0000-000000000002'::uuid) = 0,
  '76 a member sees only their own deliveries');
select mark_notifications_read() as n_read \gset
select tests.check(:n_read > 0 and (select count(*) from notifications where read_at is null and (user_id = auth.uid() or user_id is null)) = 0,
  '77 mark all as read', :'n_read');
reset role;

-- ───────── 13. regulatory intelligence ─────────
set role authenticated;
set request.jwt.claim.sub = 'a1000000-0000-0000-0000-000000000001';
select tests.expect_error($$select log_regulatory_change('d0000000-0000-0000-0000-00000000000d','x','circular','https://example.invalid','official_guidance','new_circular','clarified')$$,
  '78 clients cannot log regulatory changes', 'staff only');
select tests.check((select count(*) from regulatory_changes) = 0, '79 clients cannot read raw regulatory changes');
set request.jwt.claim.sub = '99999999-0000-0000-0000-000000000009';
select log_regulatory_change('d0000000-0000-0000-0000-00000000000d', 'FIXTURE amendment', 'notification', 'https://example.invalid/amend',
       'delegated_legislation', 'amendment', 'substituted', 'G.S.R. 0(E) fixture', '2026-10-10', '2026-10-09', '2026-11-01', null, 'India', 'Fixture Act',
       'Rule 1', '20th of next month', '15th of next month', array[(select id from rules where rule_key = 'FX-MONTHLY')]) as chg \gset
select log_regulatory_change('d0000000-0000-0000-0000-00000000000d', 'FIXTURE draft rules', 'consultation', 'https://example.invalid/draft',
       'draft_proposal', 'new_rule', 'new') as chg_draft \gset
select tests.check((select count(*) from research_queue where change_id = :'chg' and status = 'new') = 1, '80 amendment creates one research item per affected rule');
select tests.check((select count(*) from research_queue where change_id = :'chg_draft') = 0
               and (select interpretation_required from regulatory_changes where id = :'chg_draft'), '81 draft law is tracked but never queued as a rule');
select tests.check((select count(*) from change_impact(:'chg')) = 1, '82 impact report lists the affected rule');
select tests.check((select state from rule_versions v join rules r on r.id = v.rule_id where r.rule_key = 'FX-MONTHLY' and v.state = 'active') = 'active',
  '83 logging a change does not alter the active rule');
reset role;

-- ───────── 14. audit trail ─────────
select tests.check((select count(*) from audit_log where entity = 'obligation' and action = 'transition') >= 8, '84 workflow transitions audited');
select tests.check((select count(*) from audit_log where entity = 'client_contacts') >= 3 and
                   (select count(*) from audit_log where entity = 'notification_recipients') >= 3, '85 contact and recipient changes audited');
select tests.check((select count(*) from audit_log where entity = 'obligation' and action = 'due_date_change') = 1, '86 deadline revision audited');
select tests.check((select count(*) from audit_log where detail::text ilike '%verify_token_hash%') = 0, '87 verification tokens never written to the audit log');

-- ───────── 15. directory + health ─────────
set role authenticated;
set request.jwt.claim.sub = 'a2000000-0000-0000-0000-000000000002';
select tests.check((select count(*) from org_member_directory(:'org_a')) = 3, '88 member directory lists my organisation');
select tests.check((select count(*) from org_member_directory(:'org_b')) = 0, '89 member directory of another organisation is empty');
select tests.check((select count(*) from delivery_health_summary()) = 0, '90 delivery health is staff-only');
set request.jwt.claim.sub = '99999999-0000-0000-0000-000000000009';
select tests.check((select count(*) from delivery_health_summary()) > 0
               and not exists (select 1 from delivery_health_summary() where last_error ~ '@'), '91 staff health summary hides addresses');
reset role;

-- ───────── summary ─────────
\echo
select case when ok then 'PASS' else 'FAIL' end as result, name, case when not ok then detail end as detail from tests.results order by id;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from tests.results;
do $$ begin if exists (select 1 from tests.results where not ok) then raise exception 'TESTS FAILED'; end if; end $$;
