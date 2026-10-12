// Unit tests for the email layer. Run: node --experimental-strip-types --test supabase/functions/tests/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { renderReminder, renderContactVerification, recordUrl, subjectPrefix, type ReminderData } from '../_shared/templates.ts';
import { ResendProvider, NotConfiguredProvider } from '../_shared/provider.ts';
import { processBatch } from '../_shared/worker.ts';
import { verifySvix, mapResendEvent } from '../_shared/svix.ts';

const base: ReminderData = {
  delivery_id: '11111111-1111-1111-1111-111111111111', email: 'officer@example.test', recipient_name: 'Officer Test',
  company: 'Kestrel Foods Pvt Ltd', compliance: 'MGT-7', compliance_title: 'Annual return', due_date: '2026-11-29',
  current_status: 'preparing', priority: 'normal', trigger_type: 'upcoming', assigned_to: 'member@firm.test',
  required_action: 'Prepare the filing.', legal_reference: 'MCA · s.92(4)', verification_status: 'approved_rule',
  obligation_id: '22222222-2222-2222-2222-222222222222', escalation_level: 0,
};
const opts = { appUrl: 'https://app.example.test/', supportEmail: null };

test('subject: upcoming normal → [REMINDER]; high → [URGENT]', () => {
  assert.equal(renderReminder(base, opts).subject, '[REMINDER] Compliance Deadline Approaching — Kestrel Foods Pvt Ltd — MGT-7');
  assert.equal(renderReminder({ ...base, priority: 'high' }, opts).subject, '[URGENT] Compliance Deadline Approaching — Kestrel Foods Pvt Ltd — MGT-7');
});

test('subject: overdue and escalation formats', () => {
  assert.equal(renderReminder({ ...base, trigger_type: 'overdue', priority: 'critical' }, opts).subject,
    '[OVERDUE] Action Required — Kestrel Foods Pvt Ltd — MGT-7');
  assert.equal(subjectPrefix('escalation', 'critical').tag, '[ESCALATION]');
  assert.equal(subjectPrefix('due_today', 'high').tag, '[DUE TODAY]');
});

test('body contains every required field and the disclaimer', () => {
  const m = renderReminder(base, opts);
  for (const s of ['Kestrel Foods Pvt Ltd', 'MGT-7 — Annual return', '29 Nov 2026', 'In preparation', 'Normal',
                   'member@firm.test', 'Prepare the filing.', 'MCA · s.92(4)', 'https://app.example.test/?obligation=22222222-2222-2222-2222-222222222222',
                   'reflects the current status recorded in REGULENTA']) {
    assert.ok(m.text.includes(s), `text missing: ${s}`);
  }
  assert.ok(m.html.includes('Open Compliance Record'));
});

test('unverified item: provisional warning shown, legal reference withheld', () => {
  const m = renderReminder({ ...base, verification_status: 'unverified' }, opts);
  assert.ok(m.text.includes('awaiting verification'));
  assert.ok(!m.text.includes('MCA · s.92(4)'));
});

test('no header injection or HTML injection from data', () => {
  const m = renderReminder({ ...base, company: 'Evil\r\nBcc: x@y.z <script>alert(1)</script>' }, opts);
  assert.ok(!/[\r\n]/.test(m.subject));
  assert.ok(!m.html.includes('<script>'));
  assert.ok(m.html.includes('&lt;script&gt;'));
});

test('record link rejects anything but a uuid', () => {
  assert.throws(() => recordUrl('https://a.test', '../../admin'));
});

test('support line only when configured; verification email has link', () => {
  assert.ok(!renderReminder(base, opts).text.includes('Questions:'));
  assert.ok(renderReminder(base, { ...opts, supportEmail: 'help@firm.test' }).text.includes('Questions: help@firm.test'));
  const v = renderContactVerification({ name: 'A', company: 'B', link: 'https://app.test/?verify_email=abc' });
  assert.ok(v.text.includes('https://app.test/?verify_email=abc'));
});

function fakeFetch(status: number, body: unknown, capture?: { req?: RequestInit; url?: string }) {
  return async (url: string, init?: RequestInit) => {
    if (capture) { capture.url = url; capture.req = init; }
    return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
  };
}

test('Resend: success returns message id; key only in Authorization header; idempotency key set', async () => {
  const cap: { req?: RequestInit; url?: string } = {};
  const p = new ResendProvider('re_test_key', 'REGULENTA <reminders@example.test>', fakeFetch(200, { id: 'msg_1' }, cap));
  const r = await p.send({ to: 'a@b.test', subject: 's', html: 'h', text: 't', idempotencyKey: 'del-1' });
  assert.deepEqual(r, { ok: true, messageId: 'msg_1' });
  const h = cap.req!.headers as Record<string, string>;
  assert.equal(h['Authorization'], 'Bearer re_test_key');
  assert.equal(h['Idempotency-Key'], 'del-1');
  assert.ok(!String(cap.req!.body).includes('re_test_key'));
  assert.equal(cap.url, 'https://api.resend.com/emails');
});

test('Resend: 422 is permanent, 429/500 and network errors are retried', async () => {
  const mk = (s: number) => new ResendProvider('k', 'f@x.test', fakeFetch(s, { name: 'err', message: 'm' }));
  assert.equal((await mk(422).send({ to: 'a', subject: '', html: '', text: '', idempotencyKey: '1' })).permanent, true);
  assert.equal((await mk(429).send({ to: 'a', subject: '', html: '', text: '', idempotencyKey: '1' })).permanent, false);
  assert.equal((await mk(500).send({ to: 'a', subject: '', html: '', text: '', idempotencyKey: '1' })).permanent, false);
  const net = new ResendProvider('k', 'f@x.test', async () => { throw new Error('ECONNRESET'); });
  const r = await net.send({ to: 'a', subject: '', html: '', text: '', idempotencyKey: '1' });
  assert.equal(r.ok, false); assert.equal(r.permanent, false);
});

test('Resend refuses to start without key or sender; not-configured provider never reports success', async () => {
  assert.throws(() => new ResendProvider('', 'f@x.test'));
  assert.throws(() => new ResendProvider('k', ''));
  assert.equal((await new NotConfiguredProvider().send()).ok, false);
});

test('worker: sends each claimed row and records accepted / retry / failed', async () => {
  const rows = [1, 2, 3].map(i => ({ ...base, delivery_id: `0000000${i}-0000-0000-0000-000000000000` }));
  const recorded: Record<string, unknown>[] = [];
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    if (fn === 'claim_email_deliveries') return { data: rows, error: null };
    recorded.push(args);
    return { data: args.p_ok ? 'accepted' : args.p_permanent ? 'failed' : 'queued', error: null };
  };
  let n = 0;
  const provider = { name: 'fake', send: async () => [{ ok: true, messageId: 'm1' }, { ok: false, error: 'timeout' }, { ok: false, error: 'bad', permanent: true }][n++] };
  const r = await processBatch(rpc, provider, opts);
  assert.deepEqual({ claimed: r.claimed, accepted: r.accepted, retrying: r.retrying, failed: r.failed }, { claimed: 3, accepted: 1, retrying: 1, failed: 1 });
  assert.equal(recorded[0].p_message_id, 'm1');
  assert.equal(recorded[0].p_provider, 'fake');
  assert.equal(recorded[2].p_permanent, true);
});

test('worker: a claim error stops the batch (nothing is sent)', async () => {
  let sent = 0;
  await assert.rejects(processBatch(async () => ({ data: null, error: { message: 'permission denied' } }),
    { name: 'x', send: async () => { sent++; return { ok: true }; } }, opts));
  assert.equal(sent, 0);
});

test('Resend webhook signature: valid accepted, tampered/old rejected', async () => {
  const secretBytes = Buffer.from('test-secret-bytes-0123456789');
  const secret = 'whsec_' + secretBytes.toString('base64');
  const id = 'msg_abc', ts = '1760000000', body = '{"type":"email.delivered","data":{"email_id":"e1"}}';
  const sig = createHmac('sha256', secretBytes).update(`${id}.${ts}.${body}`).digest('base64');
  const h = { id, timestamp: ts, signature: `v1,${sig}` };
  assert.equal(await verifySvix(secret, h, body, 1760000010), true);
  assert.equal(await verifySvix(secret, h, body.replace('delivered', 'bounced'), 1760000010), false);
  assert.equal(await verifySvix(secret, h, body, 1760009999), false);
  assert.equal(await verifySvix(secret, { ...h, signature: 'v1,AAAA' }, body, 1760000010), false);
  assert.equal(mapResendEvent('email.bounced'), 'bounced');
  assert.equal(mapResendEvent('email.opened'), null);
});
