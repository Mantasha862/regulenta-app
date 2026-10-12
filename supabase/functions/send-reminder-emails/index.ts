// Edge Function: send queued compliance reminder emails through Resend.
// Called every few minutes by pg_cron (via pg_net) with the x-cron-secret header. Not callable from the browser.
// Secrets (set with `supabase secrets set`): RESEND_API_KEY, EMAIL_FROM, APP_URL, CRON_SECRET; optional EMAIL_REPLY_TO, SUPPORT_EMAIL.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import { ResendProvider } from '../_shared/provider.ts';
import { processBatch, type Rpc } from '../_shared/worker.ts';

function sameSecret(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  const env = (k: string) => Deno.env.get(k) ?? '';
  if (!sameSecret(req.headers.get('x-cron-secret') ?? '', env('CRON_SECRET'))) {
    return new Response('forbidden', { status: 403 });
  }
  const missing = ['RESEND_API_KEY', 'EMAIL_FROM', 'APP_URL', 'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY'].filter(k => !env(k));
  if (missing.length) {
    // Nothing is claimed, so queued emails stay queued (not marked sent) until configuration is complete.
    return Response.json({ status: 'not_configured', missing }, { status: 503 });
  }

  const db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
  const rpc: Rpc = async (fn, args) => {
    const { data, error } = await db.rpc(fn, args);
    return { data, error: error ? { message: error.message } : null };
  };
  const provider = new ResendProvider(env('RESEND_API_KEY'), env('EMAIL_FROM'), fetch, env('EMAIL_REPLY_TO') || undefined);
  const opts = { appUrl: env('APP_URL'), supportEmail: env('SUPPORT_EMAIL') || null, limit: 25 };

  const started = Date.now();
  const totals = { batches: 0, claimed: 0, accepted: 0, retrying: 0, failed: 0, errors: [] as string[] };
  try {
    // keep going while full batches come back, within a 40-second budget
    while (Date.now() - started < 40_000) {
      const r = await processBatch(rpc, provider, opts);
      totals.batches++; totals.claimed += r.claimed; totals.accepted += r.accepted;
      totals.retrying += r.retrying; totals.failed += r.failed; totals.errors.push(...r.errors);
      if (r.claimed < opts.limit) break;
    }
  } catch (e) {
    return Response.json({ status: 'error', message: (e as Error).message, ...totals }, { status: 500 });
  }
  // "accepted" means Resend accepted the request; "delivered" is recorded later by the resend-webhook function.
  return Response.json({ status: 'ok', ...totals });
});
