// Edge Function: Resend delivery webhooks → delivery status (delivered / bounced / complained).
// Configure in Resend: endpoint https://<project>.supabase.co/functions/v1/resend-webhook,
// events email.delivered, email.bounced, email.complained. Secret: RESEND_WEBHOOK_SECRET (whsec_...).
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import { verifySvix, mapResendEvent } from '../_shared/svix.ts';

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  const secret = Deno.env.get('RESEND_WEBHOOK_SECRET') ?? '';
  if (!secret) return new Response('webhook secret not configured', { status: 503 });
  const body = await req.text();
  const ok = await verifySvix(secret, {
    id: req.headers.get('svix-id'), timestamp: req.headers.get('svix-timestamp'), signature: req.headers.get('svix-signature'),
  }, body);
  if (!ok) return new Response('invalid signature', { status: 401 });

  let evt: { type?: string; data?: { email_id?: string; bounce?: { message?: string } } };
  try { evt = JSON.parse(body); } catch { return new Response('bad json', { status: 400 }); }
  const kind = mapResendEvent(evt.type ?? '');
  if (!kind || !evt.data?.email_id) return Response.json({ ignored: evt.type ?? null });

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const { data, error } = await db.rpc('record_provider_event', {
    p_provider: 'resend', p_message_id: evt.data.email_id, p_event: kind, p_detail: evt.data.bounce?.message ?? null,
  });
  if (error) return new Response(error.message, { status: 500 });   // Resend retries on non-2xx
  return Response.json({ recorded: data === true, event: kind });
});
