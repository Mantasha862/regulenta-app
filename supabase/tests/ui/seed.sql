-- UI test seed (fixture data only — not real law). Users, a reviewer and approved FIXTURE rules.
create role authenticator login noinherit;
grant anon, authenticated, service_role to authenticator;
insert into auth.users(id, email) values
 ('a1000000-0000-0000-0000-000000000001','owner@firma.test'),
 ('a3000000-0000-0000-0000-000000000003','admin2@firma.test'),
 ('99999999-0000-0000-0000-000000000009','reviewer@platform.test');
insert into platform_roles values ('99999999-0000-0000-0000-000000000009','reviewer');
insert into regulatory_authorities(id, code, name) values ('d0000000-0000-0000-0000-00000000000d','FIXT','Fixture Authority (test only)');
insert into regulatory_documents(id, authority_id, title, doc_type, official_url, status)
values ('dd000000-0000-0000-0000-0000000000dd','d0000000-0000-0000-0000-00000000000d','FIXTURE DOCUMENT — not real law','notification','https://example.invalid/fixture','current');
insert into research_queue(id, proposed, evidence, confidence, effective_date) values
 ('e1000000-0000-0000-0000-000000000001',
  '{"rule_key":"FX-MONTHLY","law":"OTHER","form":"FX-M","title":"Fixture monthly return","kind":"recurring","schedule":{"type":"monthly_day","day":20},"due_text":"20th of next month","applies_when":{},"authority":"Fixture Authority","section_or_rule":"Rule 1 (fixture)"}',
  '[{"document_id":"dd000000-0000-0000-0000-0000000000dd","passage":"fixture passage","page":1}]','high','2026-01-01'),
 ('e2000000-0000-0000-0000-000000000002',
  '{"rule_key":"FX-QTR","law":"OTHER","form":"FX-Q","title":"Fixture quarterly statement","kind":"recurring","schedule":{"type":"after_period_end","period":"quarter","days":21,"day_type":"calendar"},"due_text":"21 days after quarter end","applies_when":{}}',
  '[{"document_id":"dd000000-0000-0000-0000-0000000000dd","passage":"fixture passage","page":2}]','high','2026-01-01'),
 ('e4000000-0000-0000-0000-000000000004',
  '{"rule_key":"FX-LISTED","law":"OTHER","form":"FX-L","title":"Fixture listed-only item","kind":"fixed","schedule":{"type":"annual_fixed","day":30,"month":5},"due_text":"30 May","applies_when":{"listed":true}}',
  '[{"document_id":"dd000000-0000-0000-0000-0000000000dd","passage":"fixture passage","page":4}]','high','2026-01-01'),
 ('e5000000-0000-0000-0000-000000000005',
  '{"rule_key":"FX-PENDING","law":"OTHER","form":"FX-P","title":"Fixture item awaiting review","kind":"fixed","schedule":{"type":"annual_fixed","day":1,"month":1},"due_text":"1 Jan","applies_when":{}}',
  '[]','low','2026-01-01');
set role authenticated;
set request.jwt.claim.sub = '99999999-0000-0000-0000-000000000009';
select approve_rule_change(id, 'fixture approval') from research_queue where id in
  ('e1000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000002','e4000000-0000-0000-0000-000000000004');
reset role;
