// End-to-end: the real worker code against the real claim/record SQL functions on the LOCAL test database,
// with a fake provider (no email leaves this machine). Requires run-local.sh to have been run first.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import { processBatch, type Rpc } from '../../_shared/worker.ts';

const client = new pg.Client({ host: process.env.PGHOST ?? '/var/tmp/regulenta-pg', port: 54329, user: 'postgres', database: 'regulenta_test' });

const rpc: Rpc = async (fn, args) => {
  try {
    if (fn === 'claim_email_deliveries') {
      const r = await client.query('select * from claim_email_deliveries($1)', [args.p_limit]);
      return { data: r.rows.map(x => ({ ...x, due_date: x.due_date.toISOString().slice(0, 10) })), error: null };
    }
    if (fn === 'record_email_result') {
      const r = await client.query('select record_email_result($1,$2,$3,$4,$5,$6) as s',
        [args.p_delivery, args.p_ok, args.p_provider, args.p_message_id, args.p_error, args.p_permanent]);
      return { data: r.rows[0].s, error: null };
    }
    return { data: null, error: { message: 'unknown rpc' } };
  } catch (e) { return { data: null, error: { message: (e as Error).message } }; }
};

test('worker sends queued reminders through the real SQL and records provider ids', async () => {
  await client.connect();
  try {
  await client.query('set role service_role');
  // fresh events on a new day so there is something queued
  await client.query(`select generate_notification_events('2027-01-20')`);
  await client.query(`update notification_deliveries set next_attempt_at = now() - interval '1 minute' where status = 'queued'`);
  const queued = Number((await client.query(`select count(*) from notification_deliveries where status = 'queued' and channel = 'email'`)).rows[0].count);
  assert.ok(queued > 0, 'expected queued emails');
  const sent: string[] = [];
  const provider = { name: 'fake-e2e', send: async (m: { to: string; subject: string }) => { sent.push(`${m.to} | ${m.subject}`); return { ok: true, messageId: `fake-${sent.length}` }; } };
  const r = await processBatch(rpc, provider, { appUrl: 'https://app.example.test', limit: 200 });
  assert.equal(r.claimed, queued);
  assert.equal(r.accepted, queued);
  assert.deepEqual(r.errors, []);
  const after = (await client.query(`select count(*) filter (where status = 'accepted' and provider = 'fake-e2e' and provider_message_id like 'fake-%') as ok,
                                             count(*) filter (where status = 'queued' and next_attempt_at <= now()) as left from notification_deliveries where channel = 'email'`)).rows[0];
  assert.equal(Number(after.ok), queued);
  assert.equal(Number(after.left), 0);
  // nobody outside the configured recipients was emailed
  assert.ok(sent.every(s => !s.startsWith('director@')), 'unauthorised contact emailed');
  console.log(sent.slice(0, 4).join('\n'));
  // a second run finds nothing to send
  const again = await processBatch(rpc, provider, { appUrl: 'https://app.example.test' });
  assert.equal(again.claimed, 0);
  } finally { await client.end(); }
});
