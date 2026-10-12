#!/usr/bin/env bash
# Runs the database tests on a throwaway local Postgres 16 (never touches Supabase).
# Usage: bash supabase/tests/run-local.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PGDIR="${PGDIR:-/var/tmp/regulenta-pg}"
BIN=/usr/lib/postgresql/16/bin
PORT=54329
if [ ! -d "$PGDIR/data" ]; then
  mkdir -p "$PGDIR" && chown postgres:postgres "$PGDIR"
  su postgres -c "$BIN/initdb -D $PGDIR/data -A trust -U postgres >/dev/null"
fi
su postgres -c "$BIN/pg_ctl -D $PGDIR/data -o '-p $PORT -k $PGDIR' -l $PGDIR/log.txt status" >/dev/null 2>&1 || \
  su postgres -c "$BIN/pg_ctl -D $PGDIR/data -o '-p $PORT -k $PGDIR' -l $PGDIR/log.txt -w start" >/dev/null
P="psql -h $PGDIR -p $PORT -U postgres -q -v ON_ERROR_STOP=1"
$P -c "drop database if exists regulenta_test" -c "create database regulenta_test"
$P -d regulenta_test -f "$HERE/fixtures/00_supabase_stub_roles.sql" -f "$HERE/fixtures/01_supabase_stub_auth_storage.sql" \
   -f "$HERE/fixtures/02_baseline_schema_001_003.sql" >/dev/null
for m in "$HERE"/../migrations/*.sql; do
  case "$m" in *schedule_jobs*) echo "skipping $(basename "$m") (needs pg_cron/pg_net on Supabase)"; continue;; esac
  echo "applying $(basename "$m")"; $P -d regulenta_test -f "$m" >/dev/null
done
for t in "$HERE"/*.test.sql; do echo "running $(basename "$t")"; $P -d regulenta_test -f "$t"; done
# end-to-end: real worker code + real SQL functions + fake provider (no email leaves the machine)
HERE_FN="$HERE/../functions/tests"
if [ -d "$HERE_FN/e2e/node_modules/pg" ]; then
  echo "running email unit tests"; node --experimental-strip-types --test "$HERE_FN/email.test.ts" 2>&1 | grep -E "^# (pass|fail)"
  echo "running worker end-to-end test"; PGHOST="$PGDIR" node --experimental-strip-types --test "$HERE_FN/e2e/worker-db.e2e.test.ts" 2>&1 | grep -E "^# (pass|fail)"
fi
