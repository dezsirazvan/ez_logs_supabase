#!/usr/bin/env bash
# End-to-end tests for sql/install.sql on a local Supabase stack (Docker + supabase CLI).
# Every check uses Supabase's real services: PostgREST, Auth, Storage, pg_net, pg_cron.
#   cd test && npm install && bash run.sh
set -uo pipefail
cd "$(dirname "$0")"
HERE="$PWD"
INSTALL="$HERE/../sql/install.sql"
PORT="${RECEIVER_PORT:-8799}"
WORK="$(mktemp -d "$HOME/.ezlogs-supabase-test.XXXXXX")"   # under $HOME: shared with Docker
LOG="$WORK/received.jsonl"; STATUS="$WORK/status"
: > "$LOG"; echo 202 > "$STATUS"
PASS=0; FAIL=0

[ -d node_modules ] || npm install --silent
npx supabase status >/dev/null 2>&1 || npx supabase start -x studio,imgproxy,inbucket,edge-runtime,logflare,vector,supavisor >/dev/null
eval "$(npx supabase status -o env 2>/dev/null | grep -E '^(DB_URL|API_URL|PUBLISHABLE_KEY|SECRET_KEY)=')"
export API_URL PUBLISHABLE_KEY SECRET_KEY
DB="$DB_URL"
q() { psql "$DB" -X -At -v ON_ERROR_STOP=1 -c "$1"; }

# The receiver runs in Supabase's own Docker network, as EZLogs would sit on the internet:
# Docker Desktop's host.docker.internal proxy cuts large uploads, which would test it, not us.
NET="$(docker network ls --format '{{.Name}}' | grep -m1 'supabase_network_ezlogs-supabase-test')"
docker rm -f ezlogs-test-receiver >/dev/null 2>&1
docker run -d --rm --name ezlogs-test-receiver --network "$NET" -v "$HERE:/app:ro" -v "$WORK:/work" \
  python:3.12-alpine python -I /app/receiver.py /work/received.jsonl /work/status "$PORT" >/dev/null
ENDPOINT="http://ezlogs-test-receiver:$PORT/api/ingest/postgres"
trap 'docker rm -f ezlogs-test-receiver >/dev/null 2>&1; rm -rf "$WORK"' EXIT

ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $1${2:+ ($2)}"; }
check() { local name="$1"; shift; if out="$("$@" 2>&1)"; then ok "$name"; else bad "$name" "$out"; fi; }
# Python assertion over every row received so far: `rows` (list of dicts), `posts` (bodies).
expect() {
  local name="$1" code="$2"
  check "$name" python3 -I -c "
import json, sys
posts = [json.loads(l)['body'] for l in open('$LOG') if l.strip()]
rows = [r for p in posts for r in p['rows']]
$code" "${@:3}"
}
wait_until() { for _ in $(seq 1 "${2:-30}"); do eval "$1" && return 0; sleep 1; done; return 1; }
received() { python3 -I -c "import json;print(sum(len(json.loads(l)['body']['rows']) for l in open('$LOG') if l.strip()))"; }
outbox() { q "select count(*) from ezlogs.outbox"; }
flush_job() { q "select count(*) from cron.job where jobname = 'ezlogs-flush'"; }

echo "== same sensitive-column rules as ezlogs-nextjs"
NEXT_SQL="$HERE/../../ez_logs_agent_nextjs/sql/postgres/00_install.sql"
[ -f "$NEXT_SQL" ] || echo "  skip (ezlogs-nextjs not checked out next to this repo)"
[ -f "$NEXT_SQL" ] && check "is_sensitive_key patterns are identical" python3 -I -c "
import re, sys
def patterns(path):
    body = open(path).read().split('is_sensitive_key(k text)')[1].split('\$\$')[1]
    return re.findall(r\"'(\(.*?\))'\", body)
a, b = patterns('$INSTALL'), patterns('$NEXT_SQL')
assert a and a == b, (a, b)"

echo "== setup: a small app (tables, RLS, a storage bucket)"
q "select ezlogs.uninstall()" >/dev/null 2>&1
psql "$DB" -X -q -v ON_ERROR_STOP=1 <<'SQL' || { echo "app setup failed"; exit 1; }
DROP TABLE IF EXISTS public.items, public.feedback, public.later_table, public.pre_connect, public.api_tokens, public.wide CASCADE;
CREATE TABLE public.items (id bigserial PRIMARY KEY, name text UNIQUE NOT NULL, secret_token text,
                           settings jsonb, notes text, pairs jsonb[], created_by uuid DEFAULT auth.uid());
ALTER TABLE public.items ENABLE ROW LEVEL SECURITY;
CREATE POLICY items_team ON public.items FOR ALL TO authenticated USING (true) WITH CHECK (true);
GRANT ALL ON public.items TO authenticated, service_role;
GRANT USAGE ON SEQUENCE public.items_id_seq TO authenticated, service_role;
CREATE TABLE public.feedback (id bigserial PRIMARY KEY, message text NOT NULL);
ALTER TABLE public.feedback ENABLE ROW LEVEL SECURITY;
CREATE POLICY feedback_in ON public.feedback FOR INSERT TO anon WITH CHECK (true);
GRANT INSERT ON public.feedback TO anon; GRANT USAGE ON SEQUENCE public.feedback_id_seq TO anon;
INSERT INTO storage.buckets (id, name, public) VALUES ('files', 'files', false) ON CONFLICT DO NOTHING;
DROP POLICY IF EXISTS files_rw ON storage.objects;
CREATE POLICY files_rw ON storage.objects FOR ALL TO authenticated USING (bucket_id = 'files') WITH CHECK (bucket_id = 'files');
SQL

echo "== install"
check "install applies cleanly" psql "$DB" -X -q -v ON_ERROR_STOP=1 -f "$INSTALL"
check "re-applying (upgrade) is clean too" psql "$DB" -X -q -v ON_ERROR_STOP=1 -f "$INSTALL"
q "create table public.pre_connect (id bigserial primary key, label text); insert into public.pre_connect(label) values ('before connect')" >/dev/null
# Someone already signed in before the install: their session must be named once connect runs.
q "delete from auth.sessions where id = '00000000-0000-0000-0000-00000000005e'; delete from auth.users where id = '00000000-0000-0000-0000-0000000000ee';
   insert into auth.users (id, aud, role, email) values ('00000000-0000-0000-0000-0000000000ee', 'authenticated', 'authenticated', 'pre@example.com');
   insert into auth.sessions (id, user_id, created_at) values ('00000000-0000-0000-0000-00000000005e', '00000000-0000-0000-0000-0000000000ee', now())" >/dev/null
check "nothing is recorded before connect" test "$(q "select (select count(*) from ezlogs.outbox) + (select count(*) from pg_trigger where tgname='ezlogs_capture')")" = 0
q "CREATE OR REPLACE FUNCTION ezlogs.endpoint() RETURNS text LANGUAGE sql IMMUTABLE AS \$\$ SELECT '$ENDPOINT' \$\$" >/dev/null
check "a bad key is refused with a clear message" bash -c "! psql '$DB' -X -At -c \"select ezlogs.connect('ezl_wrongkind', 'https://abc.supabase.co')\" 2>/dev/null"
KEY="ezldb_$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
check "connect" q "select ezlogs.connect('$KEY', 'https://local-test.supabase.co')"
wait_until "python3 -I -c \"import json,sys; sys.exit(0 if any(json.loads(l)['body']['rows']==[] for l in open('$LOG') if l.strip()) else 1)\"" 15
expect "connect says hello at once (an empty post), before the app writes anything" "
assert any(p['rows']==[] and p['install_id'] for p in posts), len(posts)"
wait_until "[ \"\$(q \"select ezlogs.status()->>'hello'\")\" = 202 ]" 15
check "status shows EZLogs' answer to the hello" test "$(q "select ezlogs.status()->>'hello'")" = 202
check "the key is in Vault, not in a table" test "$(q "select count(*) from vault.decrypted_secrets where name = 'ezlogs_ingest_key' and decrypted_secret = '$KEY'")" = 1
check "public tables, auth.users and storage.objects are tracked" test "$(q "select count(*) from pg_trigger where tgname = 'ezlogs_capture' and not tgisinternal")" -ge 4
q "create table public.api_tokens (id bigserial primary key, value text)" >/dev/null
check "a table named like a secret is not tracked" test "$(q "select count(*) from pg_trigger where tgname='ezlogs_capture' and tgrelid='public.api_tokens'::regclass")" = 0

echo "== nothing is reachable through Supabase's HTTP API"
check "the ezlogs schema is not served" bash -c "! curl -sf '$API_URL/rest/v1/outbox' -H 'apikey: $PUBLISHABLE_KEY' -H 'Accept-Profile: ezlogs' >/dev/null"
check "connect can't be called over RPC" bash -c "! curl -sf -X POST '$API_URL/rest/v1/rpc/connect' -H 'apikey: $PUBLISHABLE_KEY' -H 'Content-Profile: ezlogs' -H 'Content-Type: application/json' -d '{}' >/dev/null"
check "api roles can't read the outbox" bash -c "! psql '$DB' -X -At -c 'set role authenticated; select count(*) from ezlogs.outbox' >/dev/null 2>&1"

echo "== a signed-in user's click (sign-up, insert, rename, upload, delete, a refused duplicate, sign-in)"
FLOW="$(node flows.mjs user-flow)"; echo "     $FLOW"
USER_ID="$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['userId'])" "$FLOW")"
CID="$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['cid'])" "$FLOW")"
check "the app's own requests all succeeded" python3 -I -c "
import json,sys; f=json.loads(sys.argv[1])
assert f['signUp']=='ok' and f['insert']==201 and f['update']==204 and f['upload']=='ok' and f['delete']==204, f
assert f['duplicate']==[201,409], f['duplicate']" "$FLOW"
wait_until "[ \"\$(outbox)\" = 0 ]" 30
check "everything was delivered and the outbox is empty" test "$(outbox)" = 0
expect "rows carry the user, verified by Supabase" "
mine=[r for r in rows if r['schema']=='public' and r['table']=='items' and (r.get('claims') or {}).get('sub')=='$USER_ID']
assert len(mine)>=3, len(mine)
c=mine[0]['claims']; assert c['role']=='authenticated' and c['email'].startswith('ana.') and c['name']=='Ana Test' and c['iss'].endswith('/auth/v1'), c"
expect "the click's requests share the browser's correlation id" "
tagged={(r['table'],r['op']) for r in rows if r.get('correlation_id')=='$CID'}
assert {('items','INSERT'),('items','UPDATE'),('items','DELETE'),('objects','INSERT')} <= tagged, tagged"
expect "sensitive columns never leave the database" "
assert all('secret_token' not in (r.get('new') or {}) and 'secret_token' not in (r.get('old') or {}) for r in rows)"
expect "an update carries before and after" "
u=[r for r in rows if r['table']=='items' and r['op']=='UPDATE' and r.get('correlation_id')=='$CID'][0]
assert u['old']['name'].startswith('item-') and u['new']['name'].startswith('renamed-'), u"
expect "the refused duplicate wrote nothing" "
assert sum(1 for r in rows if (r.get('new') or {}).get('name')=='fixed-duplicate-name')==1"
expect "sign-up is captured from auth.users, with the allowed columns only" "
u=[r for r in rows if r['schema']=='auth' and r['table']=='users' and r['op']=='INSERT' and r['resource_id']=='$USER_ID']
assert u, 'no sign-up row'
assert set(u[0]['new']) <= {'id','email','phone','name','created_at','invited_at','email_confirmed_at','phone_confirmed_at','last_sign_in_at','banned_until','deleted_at','is_anonymous'}, u[0]['new']
assert u[0]['new']['name']=='Ana Test'"
expect "sign-in shows as last_sign_in_at changing" "
assert any(r['table']=='users' and r['op']=='UPDATE' and (r['old'] or {}).get('last_sign_in_at')!=(r['new'] or {}).get('last_sign_in_at') for r in rows)"
expect "a sign-in sends its new session: its id and user only" "
s=[r for r in rows if r['schema']=='auth' and r['table']=='sessions' and (r.get('new') or {}).get('user_id')=='$USER_ID']
assert s and all(r['op']=='INSERT' for r in s), s
assert all(set(r['new']) <= {'id','user_id','created_at'} for r in s), s[0]['new']"
expect "a session from before the install is sent once, id and user only" "
s=[r for r in rows if r['table']=='sessions' and r['resource_id']=='00000000-0000-0000-0000-00000000005e']
assert len(s)==1 and s[0]['new']=={'id':'00000000-0000-0000-0000-00000000005e','user_id':'00000000-0000-0000-0000-0000000000ee','created_at':s[0]['new']['created_at']}, s"
expect "an upload names the file and its owner" "
o=[r for r in rows if r['schema']=='storage' and r['op']=='INSERT'][0]['new']
assert o['bucket_id']=='files' and o['name'].startswith('$USER_ID/brief-') and o['owner_id']=='$USER_ID' and o['mimetype']=='text/plain', o"
expect "every post names the install and the version" "
assert all(p['version']=='1.3.0' and p['install_id'] and p['supabase_url']=='https://local-test.supabase.co' for p in posts)"
check "the key travels only in the Authorization header" python3 -I -c "
import json
for l in open('$LOG'):
    d=json.loads(l); assert d['auth']=='Bearer ezldb_', d['auth']; assert '$KEY' not in json.dumps(d['body'])"

echo "== anonymous visitor and the app server"
node flows.mjs anon >/dev/null; node flows.mjs service >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "an anonymous write has role anon and no user" "
f=[r for r in rows if r['table']=='feedback'][0]; assert f['claims']['role']=='anon' and 'sub' not in f['claims'], f['claims']"
expect "a service-role write is marked service_role" "
s=[r for r in rows if r['table']=='items' and (r.get('new') or {}).get('name','').startswith('server-')][0]
assert s['claims']['role']=='service_role', s['claims']"

echo "== what never leaves the database"
q "insert into public.items(name, pairs, settings, notes) values ('json-secrets', ARRAY['{\"k\":\"v\",\"api_token\":\"t\"}'::jsonb], '{\"theme\":\"dark\",\"stripe_secret_key\":\"sk_live_x\",\"profile\":{\"password\":\"hunter2\",\"city\":\"Cluj\"}}', repeat('x', 50000))" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "secrets inside a json column are removed at every level" "
r=[r for r in rows if (r.get('new') or {}).get('name')=='json-secrets'][0]['new']
assert r['settings']=={'theme':'dark','profile':{'city':'Cluj'}}, r['settings']"
expect "a huge value is replaced by its size, the rest of the row kept" "
r=[r for r in rows if (r.get('new') or {}).get('name')=='json-secrets'][0]['new']
assert r['notes'].endswith('bytes, not recorded]') and r['name']=='json-secrets', r['notes'][:60]"

expect "secrets inside an array of json values are removed too" "
r=[r for r in rows if (r.get('new') or {}).get('name')=='json-secrets'][0]['new']
assert r['pairs']==[{'k':'v'}], r['pairs']"

echo "== limits that keep every post under 64 KB (pg_net stalls on bigger bodies)"
q "create table public.wide (id bigserial primary key, $(python3 -c "print(', '.join(f'c{i} text' for i in range(250)))"))" >/dev/null
q "insert into public.wide ($(python3 -c "print(', '.join(f'c{i}' for i in range(250)))")) values ($(python3 -c "print(', '.join(\"repeat('w', 120)\" for i in range(250)))"))" >/dev/null
q "update public.wide set c0 = 'changed'" >/dev/null
q "begin; select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','00000000-0000-0000-0000-00000000000a','user_metadata',json_build_object('full_name', repeat('N', 5000)))::text, true); insert into public.items(name) values ('huge-name'); commit;" >/dev/null
START=$(python3 -c 'import time;print(time.time())')
q "insert into public.items(name, settings) values ('huge-json', (select jsonb_agg(jsonb_build_object('i', g, 'v', repeat('z', 100))) from generate_series(1, 10000) g))" >/dev/null
END=$(python3 -c 'import time;print(time.time())')
check "a 1 MB json value doesn't slow the write" python3 -c "assert $END-$START < 1.0, $END-$START"
wait_until "[ \"\$(outbox)\" = 0 ]" 30
expect "a very wide row is recorded within the limit" "
w=[r for r in rows if r['table']=='wide']
assert len(w)==2 and all(len(json.dumps(r))<41000 for r in w), [len(json.dumps(r)) for r in w]"
expect "a huge user name is cut" "
h=[r for r in rows if (r.get('new') or {}).get('name')=='huge-name'][0]
assert len(h['claims']['name'])==200, len(h['claims']['name'])"
expect "a huge json value is replaced by its size" "
h=[r for r in rows if (r.get('new') or {}).get('name')=='huge-json'][0]['new']
assert h['settings'].endswith('bytes, not recorded]'), str(h['settings'])[:80]"

echo "== the actor follows the claims inside one transaction"
q "begin;
   select set_config('request.jwt.claims', '{\"role\":\"authenticated\",\"sub\":\"00000000-0000-0000-0000-0000000000a1\"}', true);
   insert into public.items(name) values ('as-a1');
   select set_config('request.jwt.claims', '{\"role\":\"authenticated\",\"sub\":\"00000000-0000-0000-0000-0000000000b2\"}', true);
   insert into public.items(name) values ('as-b2');
   commit;" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "each row has the user who wrote it" "
a=[r for r in rows if (r.get('new') or {}).get('name')=='as-a1'][0]['claims']['sub']
b=[r for r in rows if (r.get('new') or {}).get('name')=='as-b2'][0]['claims']['sub']
assert a.endswith('a1') and b.endswith('b2'), (a, b)"

echo "== re-attaching an unchanged table takes no lock"
OID_BEFORE=$(q "select oid from pg_trigger where tgname='ezlogs_capture' and tgrelid='public.items'::regclass")
q "select ezlogs.reconcile()" >/dev/null; q "select ezlogs.track('public.items')" >/dev/null
check "the trigger is left as it is" test "$(q "select oid from pg_trigger where tgname='ezlogs_capture' and tgrelid='public.items'::regclass")" = "$OID_BEFORE"

echo "== transactions"
BEFORE=$(received)
q "begin; insert into public.items(name) values ('rolled-back'); rollback;" >/dev/null 2>&1
q "begin; insert into public.items(name) values ('tx-a'); insert into public.items(name) values ('tx-b'); update public.items set name = 'tx-b2' where name = 'tx-b'; commit;" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "a rolled-back write is never sent" "assert not any((r.get('new') or {}).get('name')=='rolled-back' for r in rows)"
expect "one transaction's rows share its transaction id" "
t=[r for r in rows if (r.get('new') or {}).get('name','').startswith('tx-')]
assert len(t)==3 and len({r['txid'] for r in t})==1, t"

echo "== new tables are tracked as soon as they are created"
q "create table public.later_table (id bigserial primary key, label text); grant all on public.later_table to service_role;" >/dev/null
q "insert into public.later_table(label) values ('born later')" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "a row in a table created after connect is captured" "assert any(r['table']=='later_table' for r in rows)"

echo "== a person's untrack holds"
q "select ezlogs.untrack('public.later_table')" >/dev/null
q "update ezlogs.state set last_reconciled = null" >/dev/null       # force the next reconcile
q "insert into public.items(name) values ('reconcile-now')" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
check "reconcile does not re-attach an untracked table" test "$(q "select count(*) from pg_trigger where tgname='ezlogs_capture' and tgrelid='public.later_table'::regclass")" = 0
q "select ezlogs.track('public.later_table')" >/dev/null
check "track brings it back" test "$(q "select count(*) from pg_trigger where tgname='ezlogs_capture' and tgrelid='public.later_table'::regclass")" = 1

echo "== EZLogs down, then back"
echo 503 > "$STATUS"
for i in 1 2 3; do q "insert into public.items(name) values ('while-down-$i')" >/dev/null; done
sleep 3
check "rows wait in the outbox" test "$(outbox)" -ge 1
check "the flush job exists while rows wait" test "$(flush_job)" = 1
echo 202 > "$STATUS"
q "update ezlogs.state set paused_until = null" >/dev/null   # skip the backoff wait in the test
wait_until "[ \"\$(outbox)\" = 0 ]" 40
check "all delivered once EZLogs answers" test "$(outbox)" = 0
wait_until "[ \"\$(flush_job)\" = 0 ]" 15
check "the flush job removed itself" test "$(flush_job)" = 0

echo "== key revoked (401)"
echo 401 > "$STATUS"
q "insert into public.items(name) values ('after-revoke')" >/dev/null
wait_until "[ \"\$(q 'select coalesce(last_status,0) from ezlogs.state')\" = 401 ]" 20
check "shipping pauses for an hour" test "$(q "select (paused_until > now() + interval '50 minutes')::int from ezlogs.state")" = 1
wait_until "[ \"\$(flush_job)\" = 0 ]" 15
check "no job keeps an idle project awake while paused" test "$(flush_job)" = 0
check "the row is kept for later" test "$(outbox)" -ge 1
echo 202 > "$STATUS"
q "select ezlogs.connect('$KEY')" >/dev/null   # reconnecting resumes (the project URL is optional and kept)
check "reconnecting without the URL keeps it" test "$(q "select supabase_url from ezlogs.state")" = "https://local-test.supabase.co"
q "insert into public.items(name) values ('after-reconnect')" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 30
check "reconnecting resumes and sends what waited" test "$(outbox)" = 0

echo "== a batch EZLogs refuses for good (413) is dropped and counted, not retried forever"
echo 413 > "$STATUS"
q "insert into public.items(name) values ('refused-batch')" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 30
check "the refused rows left the outbox" test "$(outbox)" = 0
check "and were counted as dropped" test "$(q 'select dropped_total from ezlogs.state')" -ge 1
echo 202 > "$STATUS"
q "insert into public.items(name) values ('after-refused')" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 30
expect "the next post reports the dropped count" "assert posts[-1]['dropped_rows']>=1, posts[-1]['dropped_rows']"

echo "== a SERIALIZABLE transaction still gets shipped"
q "begin isolation level serializable; insert into public.items(name) values ('serializable-tx'); commit;" >/dev/null
q "select ezlogs.ensure_flush_job()" >/dev/null   # in an idle app the next write or a running job does this
wait_until "[ \"\$(outbox)\" = 0 ]" 30
expect "its row arrives" "assert any((r.get('new') or {}).get('name')=='serializable-tx' for r in rows)"

echo "== a burst of 1,000 transactions"
: > "$LOG"
for i in $(seq 1 1000); do echo "insert into public.items(name) values ('burst-$i');"; done | psql "$DB" -X -q
wait_until "[ \"\$(outbox)\" = 0 ]" 120
expect "1,000 rows delivered, each once, in posts under 64 KB" "
b=[r for r in rows if (r.get('new') or {}).get('name','').startswith('burst-')]
assert len(b)==1000 and len({r['id'] for r in b})==1000, (len(b), len({r['id'] for r in b}))
assert len(posts) <= 60 and all(len(json.dumps(p)) < 64000 for p in posts), len(posts)"

echo "== it never breaks the app"
q "alter table ezlogs.outbox rename to outbox_gone" >/dev/null
check "an app write succeeds with the outbox broken" q "insert into public.items(name) values ('outbox-broken')"
SIGNUP="$(node flows.mjs signup-only)"
check "a sign-up succeeds with the outbox broken" python3 -I -c "import json,sys; assert json.loads(sys.argv[1])['signUp']=='ok', sys.argv[1]" "$SIGNUP"
q "alter table ezlogs.outbox_gone rename to outbox" >/dev/null

echo "== concurrent writers don't wait for each other"
START=$(python3 -c 'import time;print(time.time())')
WRITERS=()
for w in $(seq 1 20); do (for i in $(seq 1 25); do echo "insert into public.items(name) values ('par-$w-$i');"; done | psql "$DB" -X -q) & WRITERS+=($!); done
wait "${WRITERS[@]}"   # only the writers: a bare `wait` would also wait for the receiver
END=$(python3 -c 'import time;print(time.time())')
check "500 inserts from 20 connections finish in under 10 s" python3 -c "assert $END-$START < 10, $END-$START"
wait_until "[ \"\$(outbox)\" = 0 ]" 60
check "and all of them are delivered" test "$(outbox)" = 0

check "no post ever went over 64 KB" python3 -I -c "
import json
sizes=[len(json.dumps(json.loads(l)['body'])) for l in open('$LOG') if l.strip()]
assert sizes and max(sizes) < 65536, max(sizes)"

echo "== one of Supabase's tables can't be tracked: the others still are"
q "drop trigger ezlogs_capture on auth.users; drop trigger ezlogs_capture on storage.objects; drop trigger ezlogs_capture on auth.sessions;
   drop function ezlogs.capture_auth_session()" >/dev/null
q "select ezlogs.attach_platform()" >/dev/null 2>&1
check "accounts and files are tracked though sessions could not be" test "$(q "select string_agg(tgrelid::regclass::text, ',' order by tgrelid::regclass::text) from pg_trigger where tgname='ezlogs_capture' and tgrelid in ('auth.users'::regclass, 'storage.objects'::regclass, 'auth.sessions'::regclass)")" = "auth.users,storage.objects"
psql "$DB" -X -q -v ON_ERROR_STOP=1 -f "$INSTALL" >/dev/null   # restores the function, and the endpoint
q "CREATE OR REPLACE FUNCTION ezlogs.endpoint() RETURNS text LANGUAGE sql IMMUTABLE AS \$\$ SELECT '$ENDPOINT' \$\$" >/dev/null
check "and sessions are tracked once they can be" test "$(q "select count(*) from pg_trigger where tgname='ezlogs_capture' and tgrelid='auth.sessions'::regclass")" = 1

echo "== upgrade from a version without sessions"
echo 202 > "$STATUS"                          # EZLogs answers normally again
q "select ezlogs.connect('$KEY')" >/dev/null   # resume after the 401 drill above
wait_until "[ \"\$(outbox)\" = 0 ]" 30
q "drop trigger ezlogs_capture on auth.sessions" >/dev/null
check "re-applying the install (no connect) starts reading sessions" bash -c "psql '$DB' -X -q -v ON_ERROR_STOP=1 -f '$INSTALL' && test \"\$(psql '$DB' -X -At -c \"select count(*) from pg_trigger where tgname='ezlogs_capture' and tgrelid='auth.sessions'::regclass\")\" = 1"
# Re-applying restores the real endpoint (app.ezlogs.io, which refuses this test key): point it
# back at the test receiver and resume.
q "CREATE OR REPLACE FUNCTION ezlogs.endpoint() RETURNS text LANGUAGE sql IMMUTABLE AS \$\$ SELECT '$ENDPOINT' \$\$" >/dev/null
q "select ezlogs.connect('$KEY')" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 30
check "an upgrade sends the sessions still valid again (EZLogs keeps one per id)" test "$(outbox)" = 0

echo "== status and uninstall"
check "connect says which version is running" bash -c "psql '$DB' -X -At -c \"select ezlogs.connect('$KEY')\" | grep -q '^Connected (EZLogs 1.3.0)\. Now recording changes to '"
check "status reports the connection" python3 -I -c "import json,sys; s=json.loads(sys.argv[1]); assert s['connected'] and s['version']=='1.3.0' and s['waiting_rows']==0 and s['dropped_total']>=1, s" "$(q 'select ezlogs.status()')"
check "the table created before connect is tracked since" test "$(q "select count(*) from pg_trigger where tgname='ezlogs_capture' and tgrelid='public.pre_connect'::regclass")" = 1
check "uninstall" q "select ezlogs.uninstall()"
check "no triggers, no schema, no key, no job are left" test "$(q "select (select count(*) from pg_trigger where tgname='ezlogs_capture') + (select count(*) from pg_namespace where nspname='ezlogs') + (select count(*) from vault.secrets where name='ezlogs_ingest_key') + (select count(*) from cron.job where jobname='ezlogs-flush') + (select count(*) from pg_event_trigger where evtname='ezlogs_track_tables')")" = 0
check "the app still writes after uninstall" q "insert into public.items(name) values ('after-uninstall')"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
