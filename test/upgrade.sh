#!/usr/bin/env bash
# Upgrade tests for sql/install.sql: every release since 1.3.0, connected and holding rows it
# could not send yet, is upgraded by applying today's install over it (what the README says
# to do). Nothing may be lost or sent twice, the key stays, and no connect is needed.
#   cd test && npm install && bash upgrade.sh
# Earlier releases are read from git history, so this runs in the monorepo checkout only.
set -uo pipefail
cd "$(dirname "$0")"
HERE="$PWD"
INSTALL="$HERE/../sql/install.sql"
PORT="${RECEIVER_PORT:-8799}"
# release => the commit that shipped it
RELEASES="1.3.0:687e179c 1.3.1:23be4425 1.4.0:4c674101 1.5.0:b4981a45"
CURRENT="$(grep -m1 -E "FUNCTION ezlogs\.version\(\)" "$INSTALL" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+")"
[ -n "$CURRENT" ] || { echo "could not read the version from install.sql"; exit 1; }

git rev-parse --verify -q 687e179c^{commit} >/dev/null || { echo "skip: earlier releases need the monorepo's git history"; exit 0; }
WORK="$(mktemp -d "$HOME/.ezlogs-supabase-upgrade.XXXXXX")"
LOG="$WORK/received.jsonl"; STATUS="$WORK/status"
: > "$LOG"; echo 202 > "$STATUS"
PASS=0; FAIL=0

[ -d node_modules ] || npm install --silent
npx supabase status >/dev/null 2>&1 || npx supabase start -x studio,imgproxy,inbucket,edge-runtime,logflare,vector,supavisor >/dev/null
eval "$(npx supabase status -o env 2>/dev/null | grep -E '^DB_URL=')"
DB="$DB_URL"
q() { psql "$DB" -X -At -v ON_ERROR_STOP=1 -c "$1"; }

NET="$(docker network ls --format '{{.Name}}' | grep -m1 'supabase_network_ezlogs-supabase-test')"
docker rm -f ezlogs-test-receiver >/dev/null 2>&1
docker run -d --rm --name ezlogs-test-receiver --network "$NET" -v "$HERE:/app:ro" -v "$WORK:/work" \
  python:3.12-alpine python -I /app/receiver.py /work/received.jsonl /work/status "$PORT" >/dev/null
ENDPOINT="http://ezlogs-test-receiver:$PORT/api/ingest/postgres"
trap 'docker rm -f ezlogs-test-receiver >/dev/null 2>&1; rm -rf "$WORK"' EXIT

ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $1${2:+ ($2)}"; }
check() { local name="$1"; shift; if out="$("$@" 2>&1)"; then ok "$name"; else bad "$name" "$out"; fi; }
expect() {
  local name="$1" code="$2"
  check "$name" python3 -I -c "
import json, sys
# Only posts EZLogs accepted: a refused post is sent again, by design.
posts = [p['body'] for p in map(json.loads, filter(str.strip, open('$LOG'))) if p['status'] < 300]
rows = [r for p in posts for r in p['rows'] if r.get('table') == 'up_items']
$code"
}
wait_until() { for _ in $(seq 1 "${2:-30}"); do eval "$1" && return 0; sleep 1; done; return 1; }
outbox() { q "select count(*) from ezlogs.outbox"; }
point_at_receiver() { q "CREATE OR REPLACE FUNCTION ezlogs.endpoint() RETURNS text LANGUAGE sql IMMUTABLE AS \$\$ SELECT '$ENDPOINT' \$\$" >/dev/null; }
triggers() { q "select coalesce(string_agg(tgname, ',' order by tgname), '') from pg_trigger where tgrelid = 'public.up_items'::regclass and tgname like 'ezlogs%'"; }
writes() { for n in "$@"; do echo "insert into public.up_items(name) values ('$n');"; done | psql "$DB" -X -q -v ON_ERROR_STOP=1; }

for pair in $RELEASES; do
  OLD="${pair%%:*}"; SHA="${pair##*:}"
  echo "== upgrade $OLD -> $CURRENT, with rows still waiting to be sent"
  : > "$LOG"; echo 202 > "$STATUS"
  q "select ezlogs.uninstall()" >/dev/null 2>&1
  check "starts from a database without EZLogs" test "$(q "select to_regnamespace('ezlogs') is null")" = t
  q "drop table if exists public.up_items; create table public.up_items (id bigserial primary key, name text not null);
     grant all on public.up_items to service_role" >/dev/null
  git show "$SHA:ez_logs_supabase/sql/install.sql" > "$WORK/old.sql"
  check "$OLD installs" psql "$DB" -X -q -v ON_ERROR_STOP=1 -f "$WORK/old.sql"
  point_at_receiver
  KEY="ezldb_$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
  check "$OLD connects" q "select ezlogs.connect('$KEY', 'https://local-test.supabase.co')"
  wait_until "[ -n \"\$(triggers)\" ]" 30
  writes sent-1 sent-2 sent-3
  wait_until "[ \"\$(outbox)\" = 0 ]" 30
  check "$OLD delivers while EZLogs answers" test "$(outbox)" = 0

  echo 503 > "$STATUS"                      # EZLogs down: rows wait in the outbox
  writes $(seq -f "queued-%g" 1 20)
  q "update public.up_items set name = 'queued-1-renamed' where name = 'queued-1'" >/dev/null
  q "delete from public.up_items where name = 'queued-2'" >/dev/null
  wait_until "[ \"\$(q 'select failures from ezlogs.state')\" -ge 1 ]" 30
  WAITING="$(outbox)"
  check "$OLD holds rows it could not send" test "$WAITING" -gt 0
  check "$OLD tried to send them and was refused" python3 -I -c "
import json
refused = [p['body'] for p in map(json.loads, filter(str.strip, open('$LOG'))) if p['status'] == 503]
assert any(str((r.get('new') or {}).get('name', '')).startswith('queued-') for p in refused for r in p['rows']), len(refused)"

  check "$CURRENT applies over $OLD" psql "$DB" -X -q -v ON_ERROR_STOP=1 -f "$INSTALL"
  point_at_receiver                         # the test's stand-in; a real install keeps app.ezlogs.io
  # The upgrade window: the table still has the old release's trigger until the flush job re-attaches it.
  writes during-1 during-2
  q "update public.up_items set name = 'during-1-renamed' where name = 'during-1'" >/dev/null
  check "the app's writes in the upgrade window succeed" test "$(q "select count(*) from public.up_items where name in ('during-1-renamed', 'during-2')")" = 2
  check "the waiting rows are kept" test "$(outbox)" -ge "$WAITING"
  check "the key is kept" test "$(q "select count(*) from vault.decrypted_secrets where name = 'ezlogs_ingest_key' and decrypted_secret = '$KEY'")" = 1
  check "still connected, now $CURRENT" python3 -I -c "import json,sys; s=json.loads(sys.argv[1]); assert s['connected'] and s['version']=='$CURRENT', s" "$(q 'select ezlogs.status()')"
  wait_until "[ \"\$(triggers)\" = ezlogs_capture_del,ezlogs_capture_ins,ezlogs_capture_upd ]" 30
  check "the table has today's capture only, never two at once" test "$(triggers)" = "ezlogs_capture_del,ezlogs_capture_ins,ezlogs_capture_upd"

  echo 202 > "$STATUS"
  # Speeds the test up: skips the old release's backoff (at most 10 minutes), which a real upgrade waits out.
  q "update ezlogs.state set paused_until = null, failures = 0" >/dev/null
  writes after-1 after-2
  wait_until "[ \"\$(outbox)\" = 0 ]" 60
  check "everything is delivered" test "$(outbox)" = 0
  expect "every insert arrives exactly once, before, during and after the upgrade" "
from collections import Counter
got = Counter((r.get('new') or {}).get('name') for r in rows if r['op'] == 'INSERT')
want = ['sent-1','sent-2','sent-3','during-1','during-2','after-1','after-2'] + ['queued-%d' % i for i in range(1, 21)]
assert sorted(got.elements()) == sorted(want), (got, len(rows))"
  expect "the updates (queued, in the upgrade window) and the delete arrive exactly once" "
ups = sorted((r.get('new') or {}).get('name') for r in rows if r['op'] == 'UPDATE')
assert ups == ['during-1-renamed', 'queued-1-renamed'], ups
assert [r['op'] for r in rows if r['op'] == 'DELETE'] == ['DELETE']"
done

q "select ezlogs.uninstall()" >/dev/null 2>&1
q "drop table if exists public.up_items" >/dev/null
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
