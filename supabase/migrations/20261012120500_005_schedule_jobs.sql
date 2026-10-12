-- REGULENTA — migration 005: schedule the reminder jobs with pg_cron.
-- STATUS: NOT APPLIED ANYWHERE. Apply only after 004, after the edge functions are deployed, and after the owner's
-- written authorisation. Enabling this starts real reminder processing (email only goes out once RESEND_API_KEY is set
-- and an organisation switches email on in its reminder settings).
--
-- Before applying, store two secrets in Supabase Vault (Dashboard → Project Settings → Vault, or SQL below run by the owner):
--   select vault.create_secret('https://<project-ref>.supabase.co', 'regulenta_project_url');
--   select vault.create_secret('<long random string, same as the CRON_SECRET function secret>', 'regulenta_cron_secret');
-- No secret value is written in this file.

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- 1. Daily at 08:30 IST (03:00 UTC): create reminder events for every company (each company's own time zone is used).
select cron.schedule('regulenta-generate-reminders', '0 3 * * *', $$select public.generate_notification_events()$$);

-- 2. Every 10 minutes: ask the email function to send what is queued (it does nothing if the queue is empty).
select cron.schedule('regulenta-send-reminder-emails', '*/10 * * * *', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'regulenta_project_url') || '/functions/v1/send-reminder-emails',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'regulenta_cron_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000)
$$);

-- To pause:   select cron.unschedule('regulenta-send-reminder-emails');
-- Job history: select * from cron.job_run_details order by start_time desc limit 20;
-- Scheduler health inside REGULENTA: select * from public.scheduler_runs order by id desc limit 20;
