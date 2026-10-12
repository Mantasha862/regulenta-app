// Edge Function: an organisation admin asks REGULENTA to verify a company contact's email address.
// The verification token is created server-side and only ever sent to the contact's inbox — the admin never sees it.
// Requires the caller's Supabase session (JWT verification on). Secrets: RESEND_API_KEY, EMAIL_FROM, APP_URL.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import { ResendProvider } from '../_shared/provider.ts';
import { renderContactVerification } from '../_shared/templates.ts';

const cors = {
  'Access-Control-Allow-Origin': Deno.env.get('APP_URL') ?? '',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: cors });
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405, headers: cors });
  const env = (k: string) => Deno.env.get(k) ?? '';
  const missing = ['RESEND_API_KEY', 'EMAIL_FROM', 'APP_URL'].filter(k => !env(k));
  if (missing.length) return Response.json({ error: 'Email is not configured yet', missing }, { status: 503, headers: cors });

  const auth = req.headers.get('Authorization') ?? '';
  const asUser = createClient(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: u } = await asUser.auth.getUser();
  if (!u?.user) return Response.json({ error: 'sign in required' }, { status: 401, headers: cors });

  let contactId = '';
  try { contactId = String((await req.json()).contact_id ?? ''); } catch { /* fallthrough */ }
  if (!/^[0-9a-f-]{36}$/i.test(contactId)) return Response.json({ error: 'contact_id required' }, { status: 400, headers: cors });

  const admin = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
  // permission is checked inside the database function (caller must be owner/admin of the contact's organisation)
  const { data: token, error } = await admin.rpc('request_contact_verification', { p_contact: contactId, p_actor: u.user.id });
  if (error) return Response.json({ error: error.message }, { status: 403, headers: cors });

  const { data: k } = await admin.from('client_contacts').select('full_name,email,clients(name)').eq('id', contactId).single();
  if (!k) return Response.json({ error: 'contact not found' }, { status: 404, headers: cors });
  const link = `${env('APP_URL').replace(/\/+$/, '')}/?verify_email=${encodeURIComponent(String(token))}`;
  const mail = renderContactVerification({
    name: k.full_name, company: (k.clients as { name?: string } | null)?.name ?? 'your company', link, supportEmail: env('SUPPORT_EMAIL') || null,
  });
  const provider = new ResendProvider(env('RESEND_API_KEY'), env('EMAIL_FROM'), fetch, env('EMAIL_REPLY_TO') || undefined);
  const sent = await provider.send({ to: k.email, ...mail, idempotencyKey: `verify-${contactId}-${Date.now()}` });
  if (!sent.ok) return Response.json({ error: `could not send: ${sent.error}` }, { status: 502, headers: cors });
  return Response.json({ sent: true }, { headers: cors });
});
