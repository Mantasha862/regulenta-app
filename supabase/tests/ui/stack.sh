#!/usr/bin/env bash
# Local UI test stack: Postgres (schema + 004 + seed) → PostgREST :3010 → built app on :5199 (proxies /rest/v1).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; APP="$HERE/../../.."; T="$HERE/.."
PGDIR=/var/tmp/regulenta-pg; P="psql -h $PGDIR -p 54329 -U postgres -q -v ON_ERROR_STOP=1"
bash "$T/run-local.sh" >/dev/null 2>&1 || true      # ensures the server is up
pkill -f "regulenta-tools/pgrst.conf" || true; sleep 1
$P -c "drop database if exists regulenta_ui" -c "drop role if exists authenticator" -c "create database regulenta_ui"
$P -d regulenta_ui -f "$T/fixtures/00_supabase_stub_roles.sql" -f "$T/fixtures/01_supabase_stub_auth_storage.sql" -f "$T/fixtures/02_baseline_schema_001_003.sql" >/dev/null
$P -d regulenta_ui -f "$APP/supabase/migrations/20261012120000_004_workflow_notifications_engine.sql" >/dev/null
$P -d regulenta_ui -f "$HERE/seed.sql" >/dev/null
cat > /var/tmp/regulenta-tools/pgrst.conf <<CONF
db-uri = "postgres://authenticator@/regulenta_ui?host=$PGDIR&port=54329"
db-schemas = "public"
db-anon-role = "anon"
jwt-secret = "local-ui-test-secret-0123456789abcdef"
server-port = 3010
CONF
nohup /var/tmp/regulenta-tools/postgrest /var/tmp/regulenta-tools/pgrst.conf > /var/tmp/regulenta-tools/pgrst.log 2>&1 &
cd "$APP"
VITE_SUPABASE_URL=http://localhost:5199 VITE_SUPABASE_PUBLISHABLE_KEY=local-test-key npx vite build --outDir /var/tmp/regulenta-tools/dist-ui >/dev/null
pkill -f "vite.ui.config" || true
nohup npx vite preview --config "$HERE/vite.ui.config.js" --outDir /var/tmp/regulenta-tools/dist-ui --port 5199 --strictPort > /var/tmp/regulenta-tools/preview.log 2>&1 &
sleep 4; curl -s -o /dev/null -w "app %{http_code}\n" http://localhost:5199/; curl -s -o /dev/null -w "api %{http_code}\n" http://localhost:5199/rest/v1/
