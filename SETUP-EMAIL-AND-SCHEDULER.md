# REGULENTA — enabling reminder emails and the scheduler (owner steps)
Nothing below has been applied. Do these only when you want reminders to go live. Order matters.

## 1. Apply the database migrations (needs your authorisation)
On the live Supabase project (ref xabjjoxpunpbhdkmwkvi), after a backup/branch test:
  004_workflow_notifications_engine.sql   (workflow, recipients, notifications, deadline engine)
  005_schedule_jobs.sql                   (pg_cron jobs — only after the edge functions are deployed)

## 2. Email provider (Resend)
- Create a Resend account and add a sending domain. Until a domain is verified, Resend only lets you send to your own address.
- **Interim sender/support address (your instruction, 12 Oct 2026): Mantasha.abid@insightjuris.in.**
  - For real sending, that domain (insightjuris.in) must be verified in Resend, OR use Resend's test domain to send only to yourself while testing.
- Function secrets (set with the Supabase CLI; these live server-side, never in the browser):
    supabase secrets set RESEND_API_KEY=...            # from Resend
    supabase secrets set EMAIL_FROM="REGULENTA <reminders@insightjuris.in>"   # or the test domain while unverified
    supabase secrets set EMAIL_REPLY_TO="Mantasha.abid@insightjuris.in"
    supabase secrets set SUPPORT_EMAIL="Mantasha.abid@insightjuris.in"
    supabase secrets set APP_URL="https://<your deployed app URL>"
    supabase secrets set CRON_SECRET="<a long random string>"
    supabase secrets set RESEND_WEBHOOK_SECRET="whsec_..."   # from the Resend webhook settings

## 3. Deploy the edge functions
    supabase functions deploy send-reminder-emails
    supabase functions deploy resend-webhook
    supabase functions deploy request-contact-verification
In Resend, add a webhook to https://<project>.supabase.co/functions/v1/resend-webhook for
email.delivered, email.bounced, email.complained.

## 4. Store the two Vault secrets used by pg_cron (step in 005), then apply 005.

## 5. Switch email on, per organisation
In the app → Reminders & recipients → "Switch on email delivery for this organisation", and add recipients.
Until this is on, reminders are recorded and shown in-app but NO email is sent.

## Safety facts
- An email is reported "accepted" only when Resend accepts it, and "delivered" only when Resend's webhook confirms it.
- Reminders go out only for obligations whose rule is approved with evidence; unverified rules raise a staff review alert instead.
- External contacts receive email only after an admin opts them in AND they confirm their address.
