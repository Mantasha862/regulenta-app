# REGULENTA
Compliance tracking for company secretaries, law firms and companies. Vite + React + Supabase.

## What's here
- `src/` — the React app (dashboard, companies, compliance workflow, notifications, reminders & recipients, review queue, regulatory intelligence, delivery health).
- `supabase/migrations/` — database migrations. 001/003 are live; **004 and 005 are NOT applied** (need authorisation).
- `supabase/functions/` — edge functions (Resend email sender, webhook, contact verification) with unit + end-to-end tests.
- `supabase/tests/` — local Postgres test suite and a browser UI test stack. Nothing here touches the live project.

## Run the app locally
    npm install && cp .env.example .env.local && npm run dev

## Run the tests locally (throwaway Postgres, no Supabase, no email leaves the machine)
    bash supabase/tests/run-local.sh          # 93 SQL + 13 email unit + 1 worker e2e
    bash supabase/tests/ui/stack.sh && python3 supabase/tests/ui/ui_test.py   # 13 browser tests

## Going live
See SETUP-EMAIL-AND-SCHEDULER.md. Deadlines appear only for rules a reviewer has approved with evidence.

## Safety
- Only the publishable key is used in the browser; the service-role key is never shipped.
- Workflow, due dates and rule activation are controlled by database functions, not direct writes.
