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
# 1 when the table has EZLogs capture (statement triggers, or the row trigger), else 0.
tracked() { q "select count(distinct tgrelid) from pg_trigger where tgname like 'ezlogs\\_capture%' and tgrelid = '$1'::regclass"; }
all_tracked() { q "select count(distinct tgrelid) from pg_trigger where tgname like 'ezlogs\\_capture%' and not tgisinternal"; }

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
DROP TABLE IF EXISTS public.items, public.feedback, public.later_table, public.pre_connect, public.api_tokens, public.wide, public.invoices, public.bills, public."order-items", public.docs15, public.bulk15, public.pairs15, public.vars15, public.keys15, public.orders15, public.purchases15, public.emb15, public.part15, public.pairs16, public.boxes, public.huge15, public.orphan15, public.schema_migrations_x, public.ar_internal_metadata, public.alias15, public.defer15, public.vc15, public.solo15, public.parent15, public.plain15, public.app_secrets15, public.stale15, public.big15, public.types15, public.ren16, public.inh16_child, public.inh16, public.inh17_child, public.inh17 CASCADE;
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA extensions;
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
check "nothing is recorded before connect" test "$(q "select (select count(*) from ezlogs.outbox) + (select count(*) from pg_trigger where tgname like 'ezlogs\_capture%')")" = 0
# 1.5.3: a branch or preview that runs install.sql (and name_records) but never connects records nothing.
q "select ezlogs.name_records('public.pre_connect', NULL)" >/dev/null
q "insert into public.pre_connect(label) values ('never connected'); update public.pre_connect set label = 'still never connected'" >/dev/null
check "a table named before connect still records nothing until connect (no outbox that never ships)" test "$(q "select (select count(*) from ezlogs.outbox) + (select count(*) from ezlogs.tx_marks)")" = 0
q "CREATE OR REPLACE FUNCTION ezlogs.endpoint() RETURNS text LANGUAGE sql IMMUTABLE AS \$\$ SELECT '$ENDPOINT' \$\$" >/dev/null
check "a bad key is refused with a clear message" bash -c "! psql '$DB' -X -At -c \"select ezlogs.connect('ezl_wrongkind', 'https://abc.supabase.co')\" 2>/dev/null"
check "a full API key in the SQL editor is told where the database key is" bash -c "psql '$DB' -X -At -c \"select ezlogs.connect('ezl_wrongkind', 'https://abc.supabase.co')\" 2>&1 | grep -q 'Settings, API keys, the Lovable · Bolt · v0 tab'"
KEY="ezldb_$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
check "connect" q "select ezlogs.connect('$KEY', 'https://local-test.supabase.co')"
wait_until "python3 -I -c \"import json,sys; sys.exit(0 if any(json.loads(l)['body']['rows']==[] for l in open('$LOG') if l.strip()) else 1)\"" 15
expect "connect says hello at once (an empty post), before the app writes anything" "
assert any(p['rows']==[] and p['install_id'] for p in posts), len(posts)"
wait_until "[ \"\$(q \"select ezlogs.status()->>'hello'\")\" = 202 ]" 15
check "status shows EZLogs' answer to the hello" test "$(q "select ezlogs.status()->>'hello'")" = 202
wait_until "[ \"\$(tracked public.items)\" = 1 ] && [ \"\$(tracked public.pre_connect)\" = 1 ]" 30
check "the app's tables are attached by the flush job, not inside connect" test "$(tracked public.items)" = 1
check "statement capture: three triggers on a table with a one-column key" test "$(q "select string_agg(tgname, ',' order by tgname) from pg_trigger where tgrelid = 'public.items'::regclass and tgname like 'ezlogs%'")" = "ezlogs_capture_del,ezlogs_capture_ins,ezlogs_capture_upd"
check "the key is in Vault, not in a table" test "$(q "select count(*) from vault.decrypted_secrets where name = 'ezlogs_ingest_key' and decrypted_secret = '$KEY'")" = 1
check "public tables, auth.users and storage.objects are tracked" test "$(all_tracked)" -ge 4
q "create table public.api_tokens (id bigserial primary key, value text)" >/dev/null
check "a table named like a secret is not tracked" test "$(tracked public.api_tokens)" = 0

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
c=mine[0]['claims']; assert c['role']=='authenticated' and c['email'].startswith('ana.') and c['name']=='Ana Test' and c['iss'].endswith('/auth/v1'), c
assert len(c.get('session_id',''))==36, c  # the login's session: names browser reports (1.5.0)"
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
assert all(p['version']=='1.5.3' and p['install_id'] and p['supabase_url']=='https://local-test.supabase.co' for p in posts)"
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

echo "== a pg_cron job's write says so; a write from psql says nothing"
q "insert into public.items(name) values ('from-psql')" >/dev/null
q "select cron.schedule('ezlogs-test-cron', '1 seconds', \$\$insert into public.items(name) select 'from-cron' where not exists (select 1 from public.items where name = 'from-cron')\$\$)" >/dev/null
cron_rows() { q "select count(*) from public.items where name = 'from-cron'"; }
wait_until "[ \"\$(cron_rows)\" = 1 ]" 20
q "select cron.unschedule('ezlogs-test-cron')" >/dev/null
wait_until "grep -q from-cron '$LOG' && [ \"\$(outbox)\" = 0 ]" 60
expect "a pg_cron job's write is marked scheduler pg_cron, and only that" "
c=[r for r in rows if (r.get('new') or {}).get('name')=='from-cron'][0]
assert c['claims']=={'scheduler': 'pg_cron'}, c['claims']
p=[r for r in rows if (r.get('new') or {}).get('name')=='from-psql'][0]
assert p.get('claims') is None, p['claims']"
check "the test job is gone" test "$(q "select count(*) from cron.job where jobname = 'ezlogs-test-cron'")" = 0

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
OID_BEFORE=$(q "select oid from pg_trigger where tgname='ezlogs_capture_ins' and tgrelid='public.items'::regclass")
q "select ezlogs.reconcile()" >/dev/null; q "select ezlogs.track('public.items')" >/dev/null
check "the trigger is left as it is" test "$(q "select oid from pg_trigger where tgname='ezlogs_capture_ins' and tgrelid='public.items'::regclass")" = "$OID_BEFORE"

echo "== transactions"
BEFORE=$(received)
q "begin; insert into public.items(name) values ('rolled-back'); rollback;" >/dev/null 2>&1
q "begin; insert into public.items(name) values ('tx-a'); insert into public.items(name) values ('tx-b'); update public.items set name = 'tx-b2' where name = 'tx-b'; commit;" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "a rolled-back write is never sent" "assert not any((r.get('new') or {}).get('name')=='rolled-back' for r in rows)"
expect "one transaction's rows share its transaction id" "
t=[r for r in rows if (r.get('new') or {}).get('name','').startswith('tx-')]
assert len(t)==3 and len({r['txid'] for r in t})==1, t"

echo "== 1.5.1: password changes and reset requests (never the hash or a token)"
PW=00000000-0000-0000-0000-0000000000f1
q "delete from auth.users where id = '$PW'; insert into auth.users (id, aud, role, email, encrypted_password) values ('$PW', 'authenticated', 'authenticated', 'pw@example.com', 'hash-one-SECRETHASH');" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
BEFORE_PW=$(received)
q "update auth.users set confirmation_token = 'tok-a', recovery_token = 'tok-b' where id = '$PW'" >/dev/null   # tokens only
wait_until "[ \"\$(outbox)\" = 0 ]" 20
q "update auth.users set encrypted_password = 'hash-two-SECRETHASH' where id = '$PW'" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
q "update auth.users set recovery_sent_at = now(), recovery_token = 'tok-c' where id = '$PW'" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "an update touching only tokens enqueues nothing; a password change and a reset request one each" "
u=[r for r in rows if r['schema']=='auth' and r['table']=='users' and r['op']=='UPDATE' and r['resource_id']=='$PW']
assert len(u)==2, u
p=[r for r in u if r['new'].get('pw_changed')]
assert len(p)==1 and p[0]['new']['pw_changed'] is True, u
s=[r for r in u if r['new'].get('recovery_sent_at')]
assert len(s)==1 and not s[0]['new'].get('pw_changed'), u"
expect "no hash, token or value derived from them is ever sent" "
raw=json.dumps(rows)
assert 'SECRETHASH' not in raw and 'tok-' not in raw and 'encrypted_password' not in raw and 'recovery_token' not in raw
for r in rows:
    if r['table']=='users' and r['resource_id']=='$PW':
        assert set(r['new'] or {}) <= {'id','email','phone','name','created_at','invited_at','email_confirmed_at','phone_confirmed_at','last_sign_in_at','recovery_sent_at','banned_until','deleted_at','is_anonymous','pw_changed'}, r"
q "delete from auth.users where id = '$PW'" >/dev/null

echo "== 1.5.0: what an update carries, and what is never read"
q "create table public.docs15 (id bigserial primary key, title text, status text, body text, blob bytea, seen_at timestamptz, settings jsonb);
   grant all on public.docs15 to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.docs15)\" = 1 ]" 10
q "insert into public.docs15 (title, status, body, blob) values ('Plan', 'draft', (select string_agg(md5(random()::text), '') from generate_series(1, 400)), decode(repeat('ab', 20000), 'hex'))" >/dev/null
q "update public.docs15 set status = 'final' where title = 'Plan'" >/dev/null
q "update public.docs15 set status = 'final' where title = 'Plan'" >/dev/null   # changes nothing
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "an update carries only what changed, plus the key and the name column" "
u=[r for r in rows if r['table']=='docs15' and r['op']=='UPDATE']
assert len(u)==1, u
assert set(u[0]['new'])=={'id','title','status'} and u[0]['old']['status']=='draft' and u[0]['new']['status']=='final', u[0]"
expect "binary and large values are replaced by their size, never read into the row" "
i=[r for r in rows if r['table']=='docs15' and r['op']=='INSERT'][0]['new']
assert i['blob'].endswith('bytes, not recorded]') and i['body'].endswith('bytes, not recorded]') and i['title']=='Plan', i"

echo "== 1.5.0: columns a person leaves out"
check "ignore_columns says what it set" test "$(q "select ezlogs.ignore_columns('public.docs15', ARRAY['seen_at'])")" = "public.docs15: leaving out seen_at"
check "ignore_columns refuses a column the table doesn't have" bash -c "psql '$DB' -X -At -c \"select ezlogs.ignore_columns('public.docs15', ARRAY['nope'])\" 2>&1 | grep -q 'has no column nope'"
q "update public.docs15 set seen_at = now()" >/dev/null
q "insert into public.docs15 (title, seen_at) values ('Second', now())" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "an update that changed only a left-out column is not recorded" "
assert len([r for r in rows if r['table']=='docs15' and r['op']=='UPDATE'])==1"
expect "a left-out column is never sent" "
s=[r for r in rows if r['table']=='docs15' and (r.get('new') or {}).get('title')=='Second'][0]['new']
assert 'seen_at' not in s and s['title']=='Second', s"

echo "== 1.5.0: a statement over 100 rows is one bulk row"
q "create table public.bulk15 (id bigserial primary key, status text, n int, api_key text, meta jsonb); grant all on public.bulk15 to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.bulk15)\" = 1 ]" 10
q "insert into public.bulk15 (status, n, api_key, meta) select 'todo', g, 'k' || g, '{\"api_token\":\"t\"}' from generate_series(1, 500) g" >/dev/null
q "update public.bulk15 set status = 'done', n = n + 1, meta = '{\"api_token\":\"t2\"}'" >/dev/null
q "update public.bulk15 set api_key = 'rotated'" >/dev/null   # only a secret column: nothing to record
q "delete from public.bulk15" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "500 inserted rows are one row: how many, and a few ids" "
b=[r for r in rows if r['table']=='bulk15' and r['op']=='INSERT']
assert len(b)==1 and b[0]['row_count']==500 and len(b[0]['bulk']['sample_ids'])==5 and not b[0].get('new'), b"
expect "a bulk update says which columns changed, with the value every row got" "
b=[r for r in rows if r['table']=='bulk15' and r['op']=='UPDATE']
assert len(b)==1 and b[0]['row_count']==500, b
c=b[0]['bulk']['columns']
assert c=={'status':'done','n':{'changed':True},'meta':{'changed':True}}, c"
expect "a bulk delete is one row too" "
b=[r for r in rows if r['table']=='bulk15' and r['op']=='DELETE']
assert len(b)==1 and b[0]['row_count']==500, b"
expect "a bulk row never carries a secret column or a json value" "
b=json.dumps([r for r in rows if r['table']=='bulk15'])
assert 'api_key' not in b and 'rotated' not in b and 'api_token' not in b, b[:300]"
check "no transaction marks are left behind" test "$(q 'select count(*) from ezlogs.tx_marks')" = 0

echo "== 1.5.0: a table without a one-column key keeps one trigger per row"
q "create table public.pairs15 (a int, b int, note text, primary key (a, b)); grant all on public.pairs15 to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.pairs15)\" = 1 ]" 10
check "it gets the row trigger" test "$(q "select tgname from pg_trigger where tgrelid='public.pairs15'::regclass and tgname like 'ezlogs%'")" = ezlogs_capture
q "insert into public.pairs15 values (1, 2, 'x'); update public.pairs15 set note = 'y'" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "and its changes arrive" "
p=[r for r in rows if r['table']=='pairs15']
assert [r['op'] for r in p]==['INSERT','UPDATE'] and p[1]['new']['note']=='y', p"

echo "== 1.5.0: a schema change on a host without event triggers"
q "alter event trigger ezlogs_track_tables disable" >/dev/null
q "alter table public.docs15 drop column status" >/dev/null
q "insert into public.docs15 (title) values ('stale-list')" >/dev/null   # captured by the old triggers: fails safely
check "the app's write succeeded" test "$(q "select count(*) from public.docs15 where title = 'stale-list'")" = 1
q "select ezlogs.queue_reconcile()" >/dev/null
wait_until "[ \"\$(q \"select ezlogs.attach_needed('public.docs15')\")\" = f ]" 20
q "alter event trigger ezlogs_track_tables enable" >/dev/null
q "insert into public.docs15 (title) values ('after-reattach')" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "reconcile sees the change and capture works again" "assert any((r.get('new') or {}).get('title')=='after-reattach' for r in rows)"

echo "== 1.5.0: columns named like the capture's own variables"
q "create table public.vars15 (id bigserial primary key, summary text, claims text, cid int, cnt int, found boolean, new text, old text, tg_op text);
   grant all on public.vars15 to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.vars15)\" = 1 ]" 10
q "insert into public.vars15 (summary, claims, cid, cnt, found, new, old, tg_op) values ('s1', 'c1', 1, 1, true, 'n', 'o', 't')" >/dev/null
q "update public.vars15 set summary = 's2'" >/dev/null
q "insert into public.vars15 (summary) select 'bulk' from generate_series(1, 150); update public.vars15 set claims = 'all'" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "a table with columns named summary, claims, new, found... is captured" "
v=[r for r in rows if r['table']=='vars15']
ops=[(r['op'], r.get('row_count')) for r in v]
assert ('INSERT', None) in ops and ('UPDATE', None) in ops and ('INSERT', 150) in ops and ('UPDATE', 151) in ops, ops
u=[r for r in v if r['op']=='UPDATE' and not r.get('row_count')][0]
assert u['new']['summary']=='s2' and u['old']['summary']=='s1', u
b=[r for r in v if r['op']=='UPDATE' and r.get('row_count')][0]
assert b['bulk']['columns']=={'claims':'all'}, b['bulk']"

echo "== 1.5.0: an update that changes keys is a count, never a wrong pairing"
q "create table public.keys15 (id int primary key, v text); grant all on public.keys15 to service_role; insert into public.keys15 values (1, 'one'), (2, 'two')" >/dev/null
wait_until "[ \"\$(tracked public.keys15)\" = 1 ]" 10
q "update public.keys15 set id = id + 10" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "two rows whose keys moved are recorded as 2 rows updated, no values" "
k=[r for r in rows if r['table']=='keys15' and r['op']=='UPDATE']
assert len(k)==1 and k[0]['row_count']==2 and not k[0].get('new') and not k[0].get('old'), k"

echo "== 1.5.0: a renamed table is recorded under its new name"
q "create table public.orders15 (id bigserial primary key, label text); grant all on public.orders15 to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.orders15)\" = 1 ]" 10
q "alter event trigger ezlogs_track_tables disable; alter table public.orders15 rename to purchases15; alter event trigger ezlogs_track_tables enable" >/dev/null
q "select ezlogs.queue_reconcile()" >/dev/null
wait_until "[ \"\$(q \"select ezlogs.attach_needed('public.purchases15')\")\" = f ]" 20
q "insert into public.purchases15 (label) values ('renamed')" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "rows arrive as purchases15" "
p=[r for r in rows if (r.get('new') or {}).get('label')=='renamed']
assert p and p[0]['table']=='purchases15', p"

echo "== 1.5.0: vectors, partitions, left-out columns on any table, name columns"
q "create table public.emb15 (id bigserial primary key, title text, embedding extensions.vector(3)); grant all on public.emb15 to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.emb15)\" = 1 ]" 10
q "insert into public.emb15 (title, embedding) select 'e' || g, '[1,2,3]' from generate_series(1, 150) g; update public.emb15 set embedding = '[3,2,1]'" >/dev/null
q "create table public.part15 (id bigint primary key, note text) partition by range (id); create table public.part15_a partition of public.part15 for values from (0) to (1000);
   grant all on public.part15, public.part15_a to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.part15)\" = 1 ]" 10
q "insert into public.part15_a values (5, 'direct'); insert into public.part15 values (6, 'parent')" >/dev/null
q "create table public.pairs16 (a int, b int, note text, seen_at timestamptz, primary key (a, b)); grant all on public.pairs16 to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.pairs16)\" = 1 ]" 10
check "ignore_columns refuses a key column" bash -c "psql '$DB' -X -At -c \"select ezlogs.ignore_columns('public.pairs16', ARRAY['a'])\" 2>&1 | grep -q 'part of the primary key'"
q "select ezlogs.ignore_columns('public.pairs16', ARRAY['seen_at'])" >/dev/null
q "insert into public.pairs16 values (1, 1, 'x', now()); update public.pairs16 set seen_at = now()" >/dev/null
q "create table public.boxes (id bigserial primary key, \"Name\" text, box_number text, qty int); grant all on public.boxes to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.boxes)\" = 1 ]" 10
q "insert into public.boxes (\"Name\", box_number, qty) values ('Big', 'B-7', 1); update public.boxes set qty = 2" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "a bulk update of a vector column is recorded" "
e=[r for r in rows if r['table']=='emb15' and r['op']=='UPDATE']
assert len(e)==1 and e[0]['bulk']['columns']=={'embedding':{'changed':True}}, e"
expect "a write made straight to a partition is recorded, under the parent's name" "
p=sorted((r['new'] or {}).get('note') for r in rows if r['table']=='part15')
assert p==['direct','parent'], p"
expect "a left-out column is never sent by a table without a one-column key, and its own update is dropped" "
p=[r for r in rows if r['table']=='pairs16']
assert [r['op'] for r in p]==['INSERT'] and 'seen_at' not in p[0]['new'], p"
expect "an update keeps the name columns the server reads (any case, <record>_number)" "
u=[r for r in rows if r['table']=='boxes' and r['op']=='UPDATE'][0]['new']
assert u.get('Name')=='Big' and u.get('box_number')=='B-7' and u['qty']==2, u"

echo "== 1.5.0: a very large update is a count, quickly"
q "create table public.huge15 (id bigserial primary key, a text, b text, c int); grant all on public.huge15 to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.huge15)\" = 1 ]" 10
q "insert into public.huge15 (a, b, c) select 'a', 'b', g from generate_series(1, 20000) g" >/dev/null
q "update public.huge15 set c = c + 1" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "20,000 rows updated: the count and a few ids, no per-column summary" "
h=[r for r in rows if r['table']=='huge15' and r['op']=='UPDATE']
assert len(h)==1 and h[0]['row_count']==20000 and 'columns' not in h[0]['bulk'] and len(h[0]['bulk']['sample_ids'])==5, h"

echo "== 1.5.0: capture functions left by a restore never stop the job"
q "create function ezlogs.cap_1_ins_deadbeef() returns trigger language plpgsql as \$\$ begin return null; end \$\$;
   create table public.orphan15 (id bigserial primary key); grant all on public.orphan15 to service_role;
   create function ezlogs.cap_2_ins_deadbeef() returns trigger language plpgsql as \$\$ begin return null; end \$\$;
   create trigger rv_other after insert on public.orphan15 for each statement execute function ezlogs.cap_2_ins_deadbeef();" >/dev/null
check "cleanup runs without an error" q "select ezlogs.drop_orphan_captures()"
check "an unused one is removed, one a trigger still uses is kept" test "$(q "select string_agg(proname, ',' order by proname) from pg_proc where proname like 'cap\\_%deadbeef'")" = "cap_2_ins_deadbeef"
q "drop table public.orphan15; select ezlogs.drop_orphan_captures()" >/dev/null

echo "== 1.5.0: a table a person tracked is refreshed after a schema change"
q "create table public.schema_migrations_x (id bigserial primary key, v text, w text)" >/dev/null
q "create table public.ar_internal_metadata (id bigserial primary key, v text, w text); grant all on public.ar_internal_metadata to service_role;" >/dev/null
q "select ezlogs.track('public.ar_internal_metadata')" >/dev/null
q "alter table public.ar_internal_metadata drop column w" >/dev/null
q "insert into public.ar_internal_metadata (v) values ('tracked-by-person')" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "its rows still arrive" "assert any((r.get('new') or {}).get('v')=='tracked-by-person' for r in rows)"

echo "== 1.5.0: second review"
q "create table public.alias15 (id bigserial primary key, s text, od text, nw text); grant all on public.alias15 to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.alias15)\" = 1 ]" 10
q "insert into public.alias15 (s, od, nw) values ('sv', 'ov', 'nv'); update public.alias15 set s = 's2'" >/dev/null
q "create table public.defer15 (id int primary key deferrable initially immediate, v text); grant all on public.defer15 to service_role; insert into public.defer15 values (1, 'one'), (2, 'two')" >/dev/null
wait_until "[ \"\$(tracked public.defer15)\" = 1 ]" 10
check "a table with a deferrable key gets the row trigger" test "$(q "select tgname from pg_trigger where tgrelid='public.defer15'::regclass and tgname like 'ezlogs%'")" = ezlogs_capture
q "create table public.vc15 (code varchar(20) primary key, label text); grant all on public.vc15 to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.vc15)\" = 1 ]" 10
check "a varchar key keeps statement capture" test "$(q "select count(*) from pg_trigger where tgrelid='public.vc15'::regclass and tgname like 'ezlogs\\_capture\\_%'")" = 3
q "insert into public.vc15 values ('A-1', 'first'); update public.vc15 set label = 'second'" >/dev/null
check "ignore_columns refuses a missing (NULL) name" bash -c "psql '$DB' -X -At -c \"select ezlogs.ignore_columns('public.vc15', ARRAY['label', NULL])\" 2>&1 | grep -q 'is missing (NULL)'"
q "create table public.solo15 (id bigint primary key, note text); grant all on public.solo15 to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.solo15)\" = 1 ]" 10
q "create table public.parent15 (id bigint primary key, note text) partition by range (id); grant all on public.parent15 to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.parent15)\" = 1 ]" 10
check "attaching a table with its own capture as a partition works (the customer's migration)" q "alter table public.parent15 attach partition public.solo15 for values from (0) to (100)"
q "insert into public.solo15 values (7, 'once')" >/dev/null
q "create table public.plain15 (id bigserial primary key, v text); grant all on public.plain15 to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.plain15)\" = 1 ]" 10
q "alter table public.plain15 rename to app_secrets15" >/dev/null
check "a table renamed to a secret-like name stops being recorded" test "$(tracked public.app_secrets15)" = 0
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "columns named s, od, nw are recorded as columns" "
a=[r for r in rows if r['table']=='alias15']
assert [x['op'] for x in a]==['INSERT','UPDATE'] and a[0]['new']['s']=='sv' and a[0]['new']['od']=='ov' and a[1]['new']['s']=='s2', a"
expect "a varchar key's changes arrive" "
v=[r for r in rows if r['table']=='vc15']
assert [x['op'] for x in v]==['INSERT','UPDATE'] and v[1]['new']['label']=='second' and v[1]['resource_id']=='A-1', v"
expect "a row written to a table that became a partition is recorded once, under its parent" "
p=[r for r in rows if (r.get('new') or {}).get('note')=='once']
assert len(p)==1 and p[0]['table']=='parent15', p"

echo "== 1.5.0: a capture that fails asks for the table to be attached again"
q "alter event trigger ezlogs_track_tables disable" >/dev/null
q "create table public.stale15 (id bigserial primary key, note text); grant all on public.stale15 to service_role;" >/dev/null
q "select ezlogs.attach('public.stale15'::regclass)" >/dev/null
q "update ezlogs.state set last_reconciled = now()" >/dev/null
q "alter table public.stale15 rename column note to remark" >/dev/null
q "insert into public.stale15 (remark) values ('lost one')" >/dev/null 2>&1
check "the failure asks the job to look again" test -z "$(q 'select last_reconciled from ezlogs.state')"
q "select ezlogs.ensure_flush_job()" >/dev/null
wait_until "[ \"\$(q \"select ezlogs.attach_needed('public.stale15')\")\" = f ]" 20
q "alter event trigger ezlogs_track_tables enable" >/dev/null
q "insert into public.stale15 (remark) values ('back again')" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "and capture works again within seconds" "assert any((r.get('new') or {}).get('remark')=='back again' for r in rows)"

echo "== 1.5.0: a bulk update over large rows stays fast"
q "create table public.big15 (id bigserial primary key, status text, body text, doc jsonb); grant all on public.big15 to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.big15)\" = 1 ]" 10
q "insert into public.big15 (status, body, doc)
   select 'a', (select string_agg(md5(random()::text || x.i || g.i), '') from generate_series(1, 1000) x(i)),
          jsonb_build_object('k', (select string_agg(md5(random()::text || y.i || g.i), '') from generate_series(1, 900) y(i)))
     from generate_series(1, 1000) g(i)" >/dev/null
q "alter table public.big15 disable trigger ezlogs_capture_upd" >/dev/null
T0=$(python3 -c 'import time;print(time.time())'); q "update public.big15 set status = 'b'" >/dev/null; T1=$(python3 -c 'import time;print(time.time())')
q "alter table public.big15 enable trigger ezlogs_capture_upd" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 60
T2=$(python3 -c 'import time;print(time.time())'); q "update public.big15 set status = 'c'" >/dev/null; T3=$(python3 -c 'import time;print(time.time())')
check "1,000 rows of 60 KB: capture adds less than the update itself" python3 -c "base=$T1-$T0; withc=$T3-$T2; assert withc < 2*base + 0.3, (base, withc)"
wait_until "[ \"\$(outbox)\" = 0 ]" 60
expect "and says what it set" "
b=[r for r in rows if r['table']=='big15' and r['op']=='UPDATE'][-1]
assert b['bulk']['columns']=={'status':'c'}, b['bulk']"

echo "== 1.5.0: third review"
q "create table public.types15 (id bigserial primary key, doc xml, b box, d interval, big text); grant all on public.types15 to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.types15)\" = 1 ]" 10
q "insert into public.types15 (doc, b, d, big) select '<a/>', '((0,0),(1,1))', '1 day', (select string_agg(md5(random()::text || x.i || g.i), '') from generate_series(1, 400) x(i)) from generate_series(1, 150) g(i)" >/dev/null
q "update public.types15 set doc = '<b/>'" >/dev/null
q "update public.types15 set b = '((5,5),(6,6))'" >/dev/null
q "update public.types15 set d = '24 hours'" >/dev/null
q "update public.types15 set big = big || ''" >/dev/null
q "update public.types15 set big = big where id <= 3" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 30
expect "bulk updates of xml, box and interval columns are each recorded with what they set" "
u=[r['bulk']['columns'] for r in rows if r['table']=='types15' and r['op']=='UPDATE']
assert u==[{'doc':'<b/>'}, {'b':'(6,6),(5,5)'}, {'d':'24:00:00'}], u"
expect "a large value sent again unchanged is not a change, in bulk or row by row" "
assert len([r for r in rows if r['table']=='types15' and r['op']=='UPDATE'])==3"

echo "== 1.5.0: the outbox can never fill the database"
echo 503 > "$STATUS"
q "update ezlogs.state set outbox_cap_bytes = 20000" >/dev/null
for i in $(seq 1 30); do echo "insert into public.items(name) values ('fill-$i-' || repeat('f', 900));"; done | psql "$DB" -X -q
q "update ezlogs.state set paused_until = null" >/dev/null
wait_until "[ -n \"\$(q 'select capture_paused_at from ezlogs.state')\" ]" 20
check "capture pauses past the cap, with the reason" test "$(q "select capture_paused_reason from ezlogs.state")" = "the outbox reached its size limit (EZLogs could not keep up)"
BEFORE_PAUSED=$(q "select count(*) from ezlogs.outbox")
check "the app writes while paused" q "insert into public.items(name) values ('while-paused')"
check "and nothing is queued for it" test "$(q "select count(*) from ezlogs.outbox")" = "$BEFORE_PAUSED"
check "status reports the pause" python3 -I -c "import json,sys; s=json.loads(sys.argv[1]); assert s['capture_paused'] and s['capture_paused']['reason'].startswith('the outbox'), s" "$(q 'select ezlogs.status()')"
echo 202 > "$STATUS"
q "update ezlogs.state set paused_until = null, failures = 0" >/dev/null
wait_until "[ -z \"\$(q 'select capture_paused_at from ezlogs.state')\" ]" 30
check "it resumes once the outbox is under half the cap" test -z "$(q 'select capture_paused_at from ezlogs.state')"
wait_until "[ \"\$(outbox)\" = 0 ]" 30
q "update ezlogs.state set outbox_cap_bytes = 52428800" >/dev/null
expect "posts sent while paused said so" "assert any((p.get('capture_paused') or {}).get('reason','').startswith('the outbox') for p in posts)"
expect "the write made while paused was not recorded" "assert not any((r.get('new') or {}).get('name')=='while-paused' for r in rows)"
q "insert into public.items(name) values ('after-resume')" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "writes are recorded again after it resumes" "assert any((r.get('new') or {}).get('name')=='after-resume' for r in rows)"

echo "== 1.5.3: a renamed column, and an old-style INHERITS table"
q "create table public.ren16 (id bigserial primary key, title text); grant all on public.ren16 to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.ren16)\" = 1 ]" 10
q "alter table public.ren16 rename column title to headline" >/dev/null
q "insert into public.ren16 (headline) values ('after column rename')" >/dev/null
q "create table public.inh16 (id bigint primary key, note text); create table public.inh16_child (extra text) inherits (public.inh16);
   grant all on public.inh16, public.inh16_child to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.inh16_child)\" = 1 ] && [ \"\$(q \"select ezlogs.attach_needed('public.inh16')\")\" = f ]" 10
q "insert into public.inh16 values (1, 'parent row'); insert into public.inh16_child values (2, 'child row', 'x'); update public.inh16 set note = note || ' changed'; delete from public.inh16" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "a column renamed after attach is recorded under its new name at once" "
r=[r for r in rows if r['table']=='ren16']
assert len(r)==1 and r[0]['new'].get('headline')=='after column rename', r"
expect "a write through an INHERITS parent records each row once, under its own table" "
got=sorted((r['table'], r['op'], r['resource_id']) for r in rows if r['table'] in ('inh16', 'inh16_child'))
assert got==sorted([('inh16','INSERT','1'),('inh16_child','INSERT','2'),('inh16','UPDATE','1'),('inh16_child','UPDATE','2'),('inh16','DELETE','1'),('inh16_child','DELETE','2')]), got"
# A new child of a parent that is busy (an open write holds it): the child is tracked at once, the
# parent moves to row capture on the flush job's next run, not 10 minutes later.
q "create table public.inh17 (id bigint primary key, note text); grant all on public.inh17 to service_role;" >/dev/null
wait_until "[ \"\$(tracked public.inh17)\" = 1 ]" 10
psql "$DB" -X -q -c "begin; insert into public.inh17 values (100, 'held'); select pg_sleep(4); commit;" >/dev/null 2>&1 &
HOLDER=$!
sleep 1
q "create table public.inh17_child (extra text) inherits (public.inh17); grant all on public.inh17_child to service_role;" >/dev/null 2>&1
check "a new INHERITS child is tracked at once, even while its parent is busy" test "$(tracked public.inh17_child)" = 1
wait $HOLDER
wait_until "[ \"\$(q \"select ezlogs.attach_needed('public.inh17')\")\" = f ]" 30
check "the busy parent is re-attached on the flush job's next runs" test "$(q "select ezlogs.attach_needed('public.inh17')")" = f
q "insert into public.inh17_child values (101, 'child', 'x'); update public.inh17 set note = note || ' changed' where id = 101" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "after the retry, a write through the busy parent records the child's row once" "
got=sorted((r['table'], r['op']) for r in rows if r['resource_id']=='101' and r['table'] in ('inh17', 'inh17_child'))
assert got==[('inh17_child','INSERT'),('inh17_child','UPDATE')], got"

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
check "reconcile does not re-attach an untracked table" test "$(tracked public.later_table)" = 0
q "select ezlogs.track('public.later_table')" >/dev/null
check "track brings it back" test "$(tracked public.later_table)" = 1

echo "== naming records by a column"
q "create table public.invoices (id bigserial primary key, reference text, amount_cents int, api_token text); grant all on public.invoices to service_role; grant usage on sequence public.invoices_id_seq to service_role;" >/dev/null
check "name_records refuses a table that doesn't exist" bash -c "psql '$DB' -X -At -c \"select ezlogs.name_records('public.nope', 'reference')\" 2>&1 | grep -q 'there is no table public.nope'"
check "name_records refuses a column that doesn't exist" bash -c "psql '$DB' -X -At -c \"select ezlogs.name_records('public.invoices', 'nope')\" 2>&1 | grep -q 'invoices has no column nope'"
check "name_records refuses a table that isn't the app's own" bash -c "psql '$DB' -X -At -c \"select ezlogs.name_records('auth.users', 'email')\" 2>&1 | grep -q 'not one of the app'"
q "create table public.\"order-items\" (id bigserial primary key, \"Item No\" text, sku text)" >/dev/null
check "name_records refuses names EZLogs would not use, rather than silently naming nothing" bash -c "psql '$DB' -X -At -c \"select ezlogs.name_records('public.\\\"order-items\\\"', 'sku')\" 2>&1 | grep -q 'plain table and column name'"
check "name_records refuses a column named like a secret" bash -c "psql '$DB' -X -At -c \"select ezlogs.name_records('public.invoices', 'api_token')\" 2>&1 | grep -q 'named like a secret'"
check "name_records says what it set" test "$(q "select ezlogs.name_records('public.invoices', 'reference')")" = "public.invoices rows are named by reference"
check "name_records can't be called over the API, signed in or not" bash -c "! curl -sf -X POST '$API_URL/rest/v1/rpc/name_records' -H 'apikey: $PUBLISHABLE_KEY' -H 'Content-Profile: ezlogs' -H 'Content-Type: application/json' -d '{\"target\":\"public.invoices\",\"column_name\":\"amount_cents\"}' >/dev/null && ! curl -sf -X POST '$API_URL/rest/v1/rpc/name_records' -H 'apikey: $PUBLISHABLE_KEY' -H 'Content-Type: application/json' -d '{\"target\":\"public.invoices\",\"column_name\":\"amount_cents\"}' >/dev/null"
check "and the setting is unchanged by those attempts" test "$(q "select column_name from ezlogs.record_names")" = reference
check "the guarded migration form runs, and runs again" q "DO \$\$ BEGIN IF to_regprocedure('ezlogs.name_records(text,text)') IS NOT NULL AND to_regclass('public.invoices') IS NOT NULL THEN PERFORM ezlogs.name_records('public.invoices', 'reference'); END IF; END \$\$;"
check "the guarded form skips a table the project doesn't have" q "DO \$\$ BEGIN IF to_regprocedure('ezlogs.name_records(text,text)') IS NOT NULL AND to_regclass('public.missing') IS NOT NULL THEN PERFORM ezlogs.name_records('public.missing', 'reference'); END IF; END \$\$;"
check "status lists it" test "$(q "select ezlogs.status()->'record_names'->>'public.invoices'")" = reference
q "insert into public.invoices(reference, amount_cents) values ('INV-0042', 1200)" >/dev/null
wait_until "[ \"\$(outbox)\" = 0 ]" 20
expect "each post says how its tables' rows are named" "assert any(p.get('names', {}).get('public.invoices') == 'reference' and any(r['table'] == 'invoices' for r in p['rows']) for p in posts)"
check "a NULL column goes back to the default" bash -c "psql '$DB' -X -At -c \"select ezlogs.name_records('public.invoices', NULL)\" | grep -q 'default columns again'"
check "and leaves no setting" test "$(q "select ezlogs.status()->'record_names'")" = "{}"
q "select ezlogs.name_records('public.invoices', 'reference')" >/dev/null
q "alter table public.invoices rename to bills" >/dev/null
check "a renamed table keeps its setting under its new name" test "$(q "select ezlogs.status()->'record_names'->>'public.bills'")" = reference
q "alter table public.bills rename to invoices; select ezlogs.name_records('public.invoices', NULL)" >/dev/null

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
check "connect says which version is running" bash -c "psql '$DB' -X -At -c \"select ezlogs.connect('$KEY')\" | grep -q '^Connected (EZLogs 1.5.3)\. Now recording changes to '"
check "status reports the connection" python3 -I -c "import json,sys; s=json.loads(sys.argv[1]); assert s['connected'] and s['version']=='1.5.3' and s['waiting_rows']==0 and s['dropped_total']>=1, s" "$(q 'select ezlogs.status()')"
check "the table created before connect is tracked since" test "$(tracked public.pre_connect)" = 1
check "uninstall" q "select ezlogs.uninstall()"
check "no triggers, no schema, no key, no job are left" test "$(q "select (select count(*) from pg_trigger where tgname like 'ezlogs\_capture%') + (select count(*) from pg_namespace where nspname='ezlogs') + (select count(*) from vault.secrets where name='ezlogs_ingest_key') + (select count(*) from cron.job where jobname='ezlogs-flush') + (select count(*) from pg_event_trigger where evtname='ezlogs_track_tables')")" = 0
check "the app still writes after uninstall" q "insert into public.items(name) values ('after-uninstall')"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
