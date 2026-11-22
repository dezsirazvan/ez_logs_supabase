#!/usr/bin/env bash
# What capture costs an app's writes, on the local Supabase stack run.sh uses (Docker + supabase CLI).
# Each workload runs on the same table without EZLogs, then with it; prints both and the overhead.
#   cd test && npm install && bash load.sh            # N=100000 rows by default
#   N=20000 bash load.sh
set -uo pipefail
cd "$(dirname "$0")"
HERE="$PWD"
INSTALL="${INSTALL:-$HERE/../sql/install.sql}"   # INSTALL=<file> compares another version
N="${N:-100000}"
PORT="${RECEIVER_PORT:-8799}"
WORK="$(mktemp -d "$HOME/.ezlogs-supabase-load.XXXXXX")"
: > "$WORK/received.jsonl"; echo 202 > "$WORK/status"

[ -d node_modules ] || npm install --silent
npx supabase status >/dev/null 2>&1 || npx supabase start -x studio,imgproxy,inbucket,edge-runtime,logflare,vector,supavisor >/dev/null
eval "$(npx supabase status -o env 2>/dev/null | grep -E '^DB_URL=')"
DB="$DB_URL"
q() { psql "$DB" -X -At -v ON_ERROR_STOP=1 -c "$1"; }
ms() { local t0; t0=$(python3 -c 'import time;print(time.time())'); psql "$DB" -X -q -v ON_ERROR_STOP=1 -c "$1" >/dev/null || return 1; python3 -c "import time;print(int((time.time()-$t0)*1000))"; }

NET="$(docker network ls --format '{{.Name}}' | grep -m1 'supabase_network_ezlogs-supabase-test')"
docker rm -f ezlogs-load-receiver >/dev/null 2>&1
docker run -d --rm --name ezlogs-load-receiver --network "$NET" -v "$HERE:/app:ro" -v "$WORK:/work" \
  python:3.12-alpine python -I /app/receiver.py /work/received.jsonl /work/status "$PORT" >/dev/null
trap 'docker rm -f ezlogs-load-receiver >/dev/null 2>&1; rm -rf "$WORK"' EXIT

q "select ezlogs.uninstall()" >/dev/null 2>&1
psql "$DB" -X -q -v ON_ERROR_STOP=1 <<SQL >/dev/null || { echo "setup failed"; exit 1; }
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA extensions;
DROP TABLE IF EXISTS public.load_items, public.load_docs CASCADE;
CREATE TABLE public.load_items (id bigserial PRIMARY KEY, title text NOT NULL, status text, n int, updated_at timestamptz DEFAULT now());
CREATE TABLE public.load_docs (id bigserial PRIMARY KEY, title text, body text, embedding extensions.vector(1536));
SQL

workloads() {
  local label="$1"
  q "truncate public.load_items, public.load_docs restart identity" >/dev/null
  local ins upd upd1 del docs
  ins=$(ms "insert into public.load_items (title, status, n) select 'item ' || g, 'todo', g from generate_series(1, $N) g")
  upd=$(ms "update public.load_items set status = 'done'")
  # Small and noisy: the best of three runs.
  upd1=$(for _ in 1 2 3; do ms "do \$\$ begin for i in 1..2000 loop update public.load_items set n = n + 1 where id = i; end loop; end \$\$"; done | sort -n | head -1)
  del=$(ms "delete from public.load_items")
  docs=$(ms "insert into public.load_docs (title, body, embedding)
             select 'doc ' || g, repeat('lorem ipsum ', 2000), (select array_agg(random())::extensions.vector(1536) from generate_series(1, 1536))
             from generate_series(1, 2000) g")
  echo "$label $ins $upd $upd1 $del $docs"
}

psql "$DB" -X -q -v ON_ERROR_STOP=1 -f "$INSTALL" >/dev/null
q "CREATE OR REPLACE FUNCTION ezlogs.endpoint() RETURNS text LANGUAGE sql IMMUTABLE AS \$\$ SELECT 'http://ezlogs-load-receiver:$PORT/api/ingest/postgres' \$\$" >/dev/null
BASE=$(workloads "without")
q "select ezlogs.connect('ezldb_$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')', 'https://local-load.supabase.co')" >/dev/null
q "select ezlogs.attach('public.load_items'::regclass); select ezlogs.attach('public.load_docs'::regclass)" >/dev/null 2>&1
q "select ezlogs.reconcile()" >/dev/null 2>&1
TRACKED=$(workloads "with")
OUTBOX=$(q "select pg_size_pretty(pg_total_relation_size('ezlogs.outbox')) || ' / ' || count(*) || ' rows' from ezlogs.outbox")
VERSION=$(q "select ezlogs.version()")
q "select ezlogs.uninstall()" >/dev/null 2>&1
q "DROP TABLE IF EXISTS public.load_items, public.load_docs CASCADE" >/dev/null

python3 -I - "$BASE" "$TRACKED" "$N" "$VERSION" "$OUTBOX" <<'PY'
import sys
base, tracked, n, version, outbox = sys.argv[1].split(), sys.argv[2].split(), sys.argv[3], sys.argv[4], sys.argv[5]
names = [f"insert {n} rows", f"update {n} rows (one statement)", "2,000 single-row updates", f"delete {n} rows", "insert 2,000 docs (24 KB text + vector)"]
print(f"EZLogs {version}: what capture adds to the app's writes (ms)")
for name, b, t in zip(names, base[1:], tracked[1:]):
    b, t = int(b), int(t)
    print(f"  {name:42} without {b:7}   with {t:7}   +{t - b:6}  ({(t / max(b, 1)):.1f}x)")
print(f"  outbox after the run: {outbox}")
PY
