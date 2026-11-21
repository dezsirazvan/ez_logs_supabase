-- EZLogs for Supabase: the database records what changed, who did it, and ships it to EZLogs.
--
-- Apply once as a migration (Lovable, Bolt, the Supabase SQL editor, `supabase db push`).
-- Re-applying upgrades in place and keeps anything still waiting to be sent.
-- Then, once, in the SQL editor (NEVER in a migration: migrations end up in git):
--
--   select ezlogs.connect('ezldb_...your database key...', 'https://<project>.supabase.co');
--
-- Nothing is recorded until connect() runs.
--
-- What it does:
--   * an AFTER trigger on every table in `public` (new tables are picked up), on auth.users
--     (sign-ups, sign-ins, account changes), on auth.sessions (a new session's id and user only)
--     and on storage.objects (files), writing one row
--     per change into ezlogs.outbox, with sensitive columns removed (inside json too) and very
--     large values cut;
--   * who did it comes from the login Supabase already verified (request.jwt.claims);
--   * when a writing transaction commits, at most once a second, the database posts what is
--     waiting to EZLogs with pg_net; rows leave the outbox only after EZLogs confirmed them;
--   * a pg_cron job (`ezlogs-flush`) exists only while rows wait or await confirmation, and
--     removes itself, so an idle project runs nothing of ours and still pauses normally.
--
-- Guarantees:
--   * it never blocks or breaks a write: per-row work is a small insert that swallows its own
--     errors; the work at commit is bounded, index-only, takes no lock anyone waits for and
--     swallows its own errors; everything else (confirmations, cleanup, new tables) runs in
--     the flush job;
--   * nothing here is reachable through Supabase's HTTP API (own schema, no grants);
--   * data only ever goes to app.ezlogs.io (hard-coded, not a setting);
--   * the key lives in Supabase Vault (readable there by the database owner and service_role,
--     as every Vault secret is; it is an ingest-only key that can never read data back).
--
-- Limits: a few hundred changed rows a second sustained (posts stay under 48 KB: pg_net stalls
-- on bigger bodies); past 500,000 waiting rows or 7 days
-- the oldest are dropped (and counted). A transaction writing many rows creates one
-- subtransaction per row (the price of never failing the app's write).
--
-- Remove everything with: select ezlogs.uninstall();

-- Robust on any Supabase host, now and when the host changes things:
-- * functions are not checked against other objects at creation (what pg_dump does), so an
--   optional extension or a changed Supabase table can't stop the install;
-- * only extensions every host allows are named (Lovable's SQL editor refuses a whole script
--   naming one outside its list); Supabase Vault ships installed on Supabase and Lovable Cloud,
--   so it is not created here, and ezlogs.connect() says what is missing, if anything;
-- * in the Supabase SQL editor the script is one transaction (it applies completely or not
--   at all); running it again is always safe either way.
SET check_function_bodies = false;

-- In the `extensions` schema, as Supabase recommends (else its Security Advisor warns about an
-- extension in public); plain if a project has no such schema.
DO $$
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
  EXCEPTION WHEN others THEN
    CREATE EXTENSION IF NOT EXISTS pg_net;
  END;
EXCEPTION WHEN others THEN
  RAISE NOTICE '[ezlogs] pg_net not available (%); enable it before ezlogs.connect()', SQLERRM;
END $$;

-- pg_cron runs the flush job (confirmations, retries, cleanup). connect() requires it.
DO $$
BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_cron;
EXCEPTION WHEN others THEN
  RAISE NOTICE '[ezlogs] pg_cron not available (%); enable it before ezlogs.connect()', SQLERRM;
END $$;

-- The older Next.js trigger install (public.ezlogs_audit_log) ships rows through the app
-- server. Two shippers on one database would send every change twice.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'ezlogs_audit' AND NOT tgisinternal) THEN
    RAISE EXCEPTION '[ezlogs] this database already has the ezlogs-nextjs triggers (public.ezlogs_audit_log). '
      'Remove them first: SELECT ezlogs_untrack(c.relname) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid '
      'WHERE t.tgname = ''ezlogs_audit'';';
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS ezlogs;
REVOKE ALL ON SCHEMA ezlogs FROM PUBLIC;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON SCHEMA ezlogs FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ezlogs.outbox (
  id             bigserial   PRIMARY KEY,
  schema_name    text        NOT NULL,
  table_name     text        NOT NULL,
  op             text        NOT NULL CHECK (op IN ('INSERT', 'UPDATE', 'DELETE')),
  old_row        jsonb,
  new_row        jsonb,
  resource_id    text,
  -- Who: a subset of the verified JWT claims (and our server agent's actor id, if set).
  -- EZLogs turns it into an actor, so that rule can improve without re-running this file.
  claims         jsonb,
  correlation_id text,
  txid           bigint      NOT NULL DEFAULT txid_current(),
  -- With txid, names the transaction even after a restore reuses transaction ids.
  tx_started_at  timestamptz NOT NULL DEFAULT transaction_timestamp(),
  captured_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  -- The pg_net request carrying this row, and when it was sent, until EZLogs confirms it.
  request_id     bigint,
  sent_at        timestamptz
);
CREATE INDEX IF NOT EXISTS outbox_unsent_idx ON ezlogs.outbox (id) WHERE request_id IS NULL;
CREATE INDEX IF NOT EXISTS outbox_request_idx ON ezlogs.outbox (request_id) WHERE request_id IS NOT NULL;

-- One row. Shipping state and what status() shows.
CREATE TABLE IF NOT EXISTS ezlogs.state (
  one              boolean     PRIMARY KEY DEFAULT true CHECK (one),
  install_id       uuid        NOT NULL DEFAULT gen_random_uuid(),
  supabase_url     text,
  connected_at     timestamptz,
  last_sent_at     timestamptz,
  last_status      int,
  last_error       text,
  failures         int         NOT NULL DEFAULT 0,
  paused_until     timestamptz,
  last_reconciled  timestamptz,
  -- Rows dropped since install (too old, too many, or refused by EZLogs). Only grows.
  dropped_total    bigint      NOT NULL DEFAULT 0,
  -- The empty post connect() sends, so EZLogs shows "Connected" at once; status() reads its reply.
  hello_request_id bigint
);
ALTER TABLE ezlogs.state ADD COLUMN IF NOT EXISTS hello_request_id bigint;
-- {"public.invoices": "reference"}: ezlogs.record_names as each post sends it, kept here so sending
-- (which also runs at commit) reads no other table. Refreshed by name_records and schema changes.
ALTER TABLE ezlogs.state ADD COLUMN IF NOT EXISTS record_names jsonb NOT NULL DEFAULT '{}'::jsonb;
INSERT INTO ezlogs.state (one) VALUES (true) ON CONFLICT DO NOTHING;

-- Tables a person took out with ezlogs.untrack(); nothing puts them back but ezlogs.track().
CREATE TABLE IF NOT EXISTS ezlogs.excluded (table_oid oid PRIMARY KEY);

-- The column a person recognises a table's rows by, set with ezlogs.name_records() when the
-- table has no name, title, number or label column. Copied to ezlogs.state.record_names, which
-- each post carries: EZLogs names each row from that column of the row it already got.
CREATE TABLE IF NOT EXISTS ezlogs.record_names (table_oid oid PRIMARY KEY, column_name text NOT NULL);

-- ---------------------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION ezlogs.version() RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT '1.4.0' $$;

-- Where data goes. A constant, never a setting: nothing inside the database can point the
-- capture at another host.
CREATE OR REPLACE FUNCTION ezlogs.endpoint() RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT 'https://app.ezlogs.io/api/ingest/postgres'
$$;

CREATE OR REPLACE FUNCTION ezlogs.connected() RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM ezlogs.state WHERE one AND connected_at IS NOT NULL)
$$;

-- ---------------------------------------------------------------------------------------
-- What a trigger knows about the row and the request
-- ---------------------------------------------------------------------------------------

-- Sensitive names never enter the outbox. Same lists as ezlogs-nextjs
-- (sql/postgres/00_install.sql, ezlogs_is_sensitive_key); a test keeps them identical.
CREATE OR REPLACE FUNCTION ezlogs.is_sensitive_key(k text) RETURNS boolean
  LANGUAGE sql IMMUTABLE
AS $$
  SELECT s ~ '(password|token|secret|api_key|credit_card|ssn|social_security|encrypted|private_key|public_key|signing_key|pem|cipher|nonce|salt|digest|signature|hmac|credential|passwd|passcode|apikey|card_number|cardnumber|cvv|cvc)'
      OR lower(k) ~ '(password|token|secret|api_key|credit_card|ssn|social_security|encrypted|private_key|public_key|signing_key|pem|cipher|nonce|salt|digest|signature|hmac|credential|passwd|passcode|apikey|card_number|cardnumber|cvv|cvc)'
      OR s ~ '(^|[^a-z0-9])(pin|otp|totp|iban|mfa|passphrase)([^a-z0-9]|$)'
    FROM (SELECT lower(regexp_replace(k, '([a-z0-9])([A-Z])', '\1_\2', 'g')) AS s) AS words
$$;

-- Bump whenever is_sensitive_key changes: triggers attached under another version fall back
-- to checking every key and are re-attached by the next reconcile.
CREATE OR REPLACE FUNCTION ezlogs.patterns_version() RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT 'p1' $$;

CREATE OR REPLACE FUNCTION ezlogs.strip_sensitive(r jsonb) RETURNS jsonb
  LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE WHEN r IS NULL THEN NULL ELSE COALESCE(
    (SELECT jsonb_object_agg(key, value) FROM jsonb_each(r) WHERE NOT ezlogs.is_sensitive_key(key)),
    '{}'::jsonb) END
$$;

-- A value too big to record: its size instead (never walked, never sent).
CREATE OR REPLACE FUNCTION ezlogs.size_marker(v jsonb) RETURNS jsonb
  LANGUAGE sql IMMUTABLE
AS $$ SELECT to_jsonb(format('[%s bytes, not recorded]', octet_length(v::text))) $$;

-- Inside a nested value (json, composite, array): drop sensitive keys at every level (a
-- `settings` column holding {"stripe_secret_key": ...}). Depth-limited; values over 16 KB are
-- replaced by their size without being walked (a big json document must not slow the write).
CREATE OR REPLACE FUNCTION ezlogs.strip_nested(j jsonb, depth int DEFAULT 0) RETURNS jsonb
  LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
  IF j IS NULL THEN
    RETURN NULL;
  ELSIF pg_column_size(j) > 16384 AND depth > 0 THEN
    RETURN ezlogs.size_marker(j);
  ELSIF jsonb_typeof(j) = 'object' THEN
    IF depth >= 6 THEN RETURN '"[nested too deep]"'::jsonb; END IF;
    RETURN COALESCE((SELECT jsonb_object_agg(key, ezlogs.strip_nested(value, depth + 1))
                       FROM jsonb_each(j) WHERE NOT ezlogs.is_sensitive_key(key)), '{}'::jsonb);
  ELSIF jsonb_typeof(j) = 'array' THEN
    IF depth >= 6 THEN RETURN '"[nested too deep]"'::jsonb; END IF;
    RETURN COALESCE((SELECT jsonb_agg(ezlogs.strip_nested(value, depth + 1)) FROM jsonb_array_elements(j)),
                    '[]'::jsonb);
  END IF;
  RETURN j;
END;
$$;

-- Every row must fit in one post (see send_batch), and an image in a text column must not
-- fill the disk. A row image over 16 KB keeps its small values and replaces bigger ones with
-- their size: first values over 1 KB, then, if still over 24 KB, values over 128 bytes.
CREATE OR REPLACE FUNCTION ezlogs.cap_values(r jsonb, max_bytes int) RETURNS jsonb
  LANGUAGE sql IMMUTABLE
AS $$
  SELECT jsonb_object_agg(key, CASE WHEN octet_length(value::text) > max_bytes THEN ezlogs.size_marker(value)
                                    ELSE value END)
    FROM jsonb_each(r)
$$;

CREATE OR REPLACE FUNCTION ezlogs.cap_size(r jsonb) RETURNS jsonb
  LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
  IF r IS NULL OR pg_column_size(r) <= 16384 THEN
    RETURN r;
  END IF;
  r := ezlogs.cap_values(r, 1024);
  IF octet_length(r::text) > 24576 THEN
    r := ezlogs.cap_values(r, 128);
  END IF;
  RETURN r;
END;
$$;

-- Who made this write, from what Supabase verified (PostgREST and storage set
-- request.jwt.claims per request after checking the JWT): role, user id, email, name, the
-- OAuth client (an AI connected through Supabase's OAuth server), the issuer, anonymous or not. Auth's own
-- writes (sign-up, sign-in) carry none. Parsed once per transaction.
CREATE OR REPLACE FUNCTION ezlogs.request_claims() RETURNS jsonb
  LANGUAGE plpgsql VOLATILE
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  raw    text := current_setting('request.jwt.claims', true);
  aid    text := NULLIF(current_setting('ezlogs.actor_id', true), '');
  src    text := COALESCE(raw, '') || '|' || COALESCE(aid, '');
  c      jsonb;
  result jsonb;
BEGIN
  -- Same claims as the last row of this session: reuse the parsed result (no json parse per
  -- row). Keyed on the raw values, so a change of user within one transaction is seen.
  IF current_setting('ezlogs.claims_src', true) = src THEN
    RETURN NULLIF(current_setting('ezlogs.claims', true), '')::jsonb;   -- our own JSON
  END IF;
  BEGIN
    c := NULLIF(raw, '')::jsonb;
  EXCEPTION WHEN others THEN
    c := NULL;
  END;
  IF jsonb_typeof(c) IS DISTINCT FROM 'object' THEN
    c := NULL;
  END IF;
  IF aid IS NOT NULL OR c IS NOT NULL THEN
    result := NULLIF(jsonb_strip_nulls(jsonb_build_object(
      'actor_id',     left(aid, 200),
      'role',         left(c->>'role', 50),
      'sub',          left(c->>'sub', 100),
      'email',        left(c->>'email', 200),
      'name',         left(COALESCE(c->'user_metadata'->>'full_name', c->'user_metadata'->>'name'), 200),
      'client_id',    left(c->>'client_id', 200),
      -- The project's own auth address, from a token it signed: which Supabase project this is.
      'iss',          left(c->>'iss', 200),
      'is_anonymous', CASE WHEN jsonb_typeof(c->'is_anonymous') = 'boolean' THEN c->'is_anonymous' END
    )), '{}'::jsonb);
  END IF;
  PERFORM set_config('ezlogs.claims', COALESCE(result::text, ''), true);
  PERFORM set_config('ezlogs.claims_src', src, true);
  RETURN result;
END;
$$;

-- The correlation id of this request: our server agent's setting, or the x-correlation-id
-- header the EZLogs browser module or server agent adds. Only our own id format counts.
-- (A browser can tag its own requests with any such id; the actor still comes from its JWT.)
CREATE OR REPLACE FUNCTION ezlogs.request_correlation_id() RETURNS text
  LANGUAGE plpgsql STABLE
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  cid  text := NULLIF(current_setting('ezlogs.correlation_id', true), '');
  raw  text;
BEGIN
  IF cid IS NULL THEN
    raw := NULLIF(current_setting('request.headers', true), '');
    IF raw IS NULL THEN
      RETURN NULL;
    END IF;
    -- No json parse (and no subtransaction) per row: pull the header with a pattern.
    cid := substring(raw from '"x-(?:ezlogs-)?correlation-id"\s*:\s*"(ezl_[0-9]{1,16}_[0-9a-f]{8})"');
  END IF;
  IF cid ~ '^ezl_[0-9]{1,16}_[0-9a-f]{8}$' THEN
    RETURN cid;
  END IF;
  RETURN NULL;
END;
$$;

-- Every outbox row fits in one post: after cap_size, a change whose before and after images
-- still exceed 40 KB keeps only its id and a note (a 250-column row can).
CREATE OR REPLACE FUNCTION ezlogs.enqueue(p_schema text, p_table text, p_op text, p_old jsonb, p_new jsonb, p_resource_id text)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  old_c jsonb := ezlogs.cap_size(p_old);
  new_c jsonb := ezlogs.cap_size(p_new);
BEGIN
  IF octet_length(COALESCE(old_c::text, '')) + octet_length(COALESCE(new_c::text, '')) > 40960 THEN
    old_c := CASE WHEN old_c IS NOT NULL THEN jsonb_build_object('note', 'row too large to record') END;
    new_c := CASE WHEN new_c IS NOT NULL THEN jsonb_build_object('note', 'row too large to record') END;
  END IF;
  INSERT INTO ezlogs.outbox (schema_name, table_name, op, old_row, new_row, resource_id, claims, correlation_id)
  VALUES (p_schema, p_table, p_op, old_c, new_c, left(p_resource_id, 200),
          ezlogs.request_claims(), ezlogs.request_correlation_id());
END;
$$;

-- ---------------------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------------------

-- App tables in `public`. Arguments (set by ezlogs.attach): primary key column, sensitive
-- column names, all column names in jsonb key order, patterns version, table name, json
-- column names.
CREATE OR REPLACE FUNCTION ezlogs.capture_row() RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  pk       text := COALESCE(NULLIF(TG_ARGV[0], ''), 'id');
  old_raw  jsonb;
  new_raw  jsonb;
  old_json jsonb;
  new_json jsonb;
  col      text;
BEGIN
  IF TG_OP <> 'INSERT' THEN old_raw := to_jsonb(OLD); END IF;
  IF TG_OP <> 'DELETE' THEN new_raw := to_jsonb(NEW); END IF;

  -- Fast path: drop the precomputed sensitive columns. If the columns changed since the
  -- trigger was attached, check every key by name instead.
  IF TG_NARGS >= 6
     AND TG_ARGV[3] = ezlogs.patterns_version()
     AND ARRAY(SELECT jsonb_object_keys(COALESCE(new_raw, old_raw))) = TG_ARGV[2]::text[] THEN
    old_json := old_raw - TG_ARGV[1]::text[];
    new_json := new_raw - TG_ARGV[1]::text[];
    FOREACH col IN ARRAY TG_ARGV[5]::text[] LOOP
      IF old_json ? col THEN old_json := jsonb_set(old_json, ARRAY[col], COALESCE(ezlogs.strip_nested(old_json->col, 1), 'null')); END IF;
      IF new_json ? col THEN new_json := jsonb_set(new_json, ARRAY[col], COALESCE(ezlogs.strip_nested(new_json->col, 1), 'null')); END IF;
    END LOOP;
  ELSE
    old_json := ezlogs.strip_nested(old_raw);
    new_json := ezlogs.strip_nested(new_raw);
  END IF;

  IF TG_OP = 'UPDATE' AND old_json = new_json THEN
    RETURN NULL;
  END IF;

  PERFORM ezlogs.enqueue(TG_TABLE_SCHEMA, COALESCE(NULLIF(TG_ARGV[4], ''), TG_TABLE_NAME), TG_OP,
                         old_json, new_json, COALESCE(new_json->>pk, old_json->>pk));
  RETURN NULL;
EXCEPTION WHEN others THEN
  -- Never break the app's write. Losing one change is recoverable; a failed save is not.
  RAISE WARNING '[ezlogs] capture on %.% failed (write continues): %', TG_TABLE_SCHEMA, TG_TABLE_NAME, SQLERRM;
  RETURN NULL;
END;
$$;

DROP FUNCTION IF EXISTS ezlogs.auth_user_view(auth.users);
DROP FUNCTION IF EXISTS ezlogs.storage_object_view(storage.objects);

-- auth.users: a fixed list of columns, never the whole row (password hash, tokens and
-- metadata stay out). Auth's own server writes this table; the row itself is the user.
-- Read through to_jsonb, never by column, so a column Supabase adds, renames or drops can't
-- break the install or the capture (a missing column is simply absent).
CREATE OR REPLACE FUNCTION ezlogs.auth_user_view(j jsonb) RETURNS jsonb
  LANGUAGE sql IMMUTABLE
AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'id',                 j->'id',
    'email',              j->'email',
    'phone',              j->'phone',
    'name',               left(COALESCE(j->'raw_user_meta_data'->>'full_name', j->'raw_user_meta_data'->>'name'), 200),
    'created_at',         j->'created_at',
    'invited_at',         j->'invited_at',
    'email_confirmed_at', j->'email_confirmed_at',
    'phone_confirmed_at', j->'phone_confirmed_at',
    'last_sign_in_at',    j->'last_sign_in_at',
    'banned_until',       j->'banned_until',
    'deleted_at',         j->'deleted_at',
    'is_anonymous',       j->'is_anonymous'))
$$;

CREATE OR REPLACE FUNCTION ezlogs.capture_auth_user() RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  old_json jsonb;
  new_json jsonb;
BEGIN
  IF TG_OP <> 'INSERT' THEN old_json := ezlogs.auth_user_view(to_jsonb(OLD)); END IF;
  IF TG_OP <> 'DELETE' THEN new_json := ezlogs.auth_user_view(to_jsonb(NEW)); END IF;
  IF TG_OP = 'UPDATE' AND old_json = new_json THEN
    RETURN NULL;
  END IF;
  PERFORM ezlogs.enqueue('auth', 'users', TG_OP, old_json, new_json, COALESCE(new_json->>'id', old_json->>'id'));
  RETURN NULL;
EXCEPTION WHEN others THEN
  -- An error here must never block a sign-up or sign-in.
  RAISE WARNING '[ezlogs] capture on auth.users failed (write continues): %', SQLERRM;
  RETURN NULL;
END;
$$;

-- auth.sessions: only a new session's id and whose it is, never anything else (no tokens, no IP,
-- no user agent). EZLogs keeps them apart, never as actions: they let a failure the person's
-- browser reports (@ezlogs/browser sends only the session id, never a token) be named from what
-- this database recorded.
CREATE OR REPLACE FUNCTION ezlogs.capture_auth_session() RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  j jsonb;
BEGIN
  j := to_jsonb(NEW);
  PERFORM ezlogs.enqueue('auth', 'sessions', 'INSERT', NULL,
                         jsonb_strip_nulls(jsonb_build_object('id', j->'id', 'user_id', j->'user_id', 'created_at', j->'created_at')),
                         j->>'id');
  RETURN NULL;
EXCEPTION WHEN others THEN
  -- An error here must never block a sign-in.
  RAISE WARNING '[ezlogs] capture on auth.sessions failed (sign-in continues): %', SQLERRM;
  RETURN NULL;
END;
$$;

-- storage.objects: which file, where, how big, whose. Storage writes as service_role, so the
-- uploader is owner_id.
CREATE OR REPLACE FUNCTION ezlogs.storage_object_view(j jsonb) RETURNS jsonb
  LANGUAGE sql IMMUTABLE
AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'id',         j->'id',
    'bucket_id',  j->'bucket_id',
    'name',       left(j->>'name', 500),
    'owner_id',   COALESCE(NULLIF(j->'owner_id', 'null'::jsonb), NULLIF(j->'owner', 'null'::jsonb)),
    'size',       j->'metadata'->>'size',
    'mimetype',   j->'metadata'->>'mimetype',
    'created_at', j->'created_at'))
$$;

CREATE OR REPLACE FUNCTION ezlogs.capture_storage_object() RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  old_json jsonb;
  new_json jsonb;
BEGIN
  IF TG_OP <> 'INSERT' THEN old_json := ezlogs.storage_object_view(to_jsonb(OLD)); END IF;
  IF TG_OP <> 'DELETE' THEN new_json := ezlogs.storage_object_view(to_jsonb(NEW)); END IF;
  IF TG_OP = 'UPDATE' AND old_json = new_json THEN
    RETURN NULL;
  END IF;
  PERFORM ezlogs.enqueue('storage', 'objects', TG_OP, old_json, new_json, COALESCE(new_json->>'id', old_json->>'id'));
  RETURN NULL;
EXCEPTION WHEN others THEN
  RAISE WARNING '[ezlogs] capture on storage.objects failed (write continues): %', SQLERRM;
  RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------------------
-- Which tables are tracked
-- ---------------------------------------------------------------------------------------

-- Never business activity: framework bookkeeping, and tables named like secrets (their rows
-- are the secrets: `api_tokens`, `user_secrets`). A person can still track them.
CREATE OR REPLACE FUNCTION ezlogs.skipped(table_name text) RETURNS boolean
  LANGUAGE sql IMMUTABLE
AS $$
  SELECT table_name ~ '^(ezlogs_audit_log|_prisma_migrations|schema_migrations|ar_internal_metadata)$'
      OR table_name ~ '^(pg_|_litestream|solid_(queue|cache|cable)|active_storage_)'
      OR ezlogs.is_sensitive_key(table_name)
$$;

-- Attach (or refresh) the capture trigger on one public table, unless it is skipped or a
-- person excluded it. Leaves a table whose trigger already has the current arguments alone.
-- Never waits for a table lock: a busy table is attached on a later run.
CREATE OR REPLACE FUNCTION ezlogs.attach(target regclass, by_person boolean DEFAULT false) RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
  SET lock_timeout = '100ms'
AS $$
DECLARE
  rel     pg_class%ROWTYPE;
  pk      text;
  secret  text[];
  cols    text[];
  jcols   text[];
  argv    text[];
BEGIN
  SELECT * INTO rel FROM pg_class WHERE oid = target;
  IF NOT FOUND OR rel.relnamespace <> 'public'::regnamespace OR rel.relkind NOT IN ('r', 'p') OR rel.relispartition
     OR (NOT by_person AND ezlogs.skipped(rel.relname))
     OR EXISTS (SELECT 1 FROM ezlogs.excluded e WHERE e.table_oid = target) THEN
    RETURN false;
  END IF;

  SELECT a.attname INTO pk
    FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
   WHERE i.indrelid = target AND i.indisprimary AND array_length(i.indkey, 1) = 1
   LIMIT 1;

  SELECT COALESCE(array_agg(a.attname::text) FILTER (WHERE ezlogs.is_sensitive_key(a.attname)), '{}'),
         ARRAY(SELECT jsonb_object_keys(jsonb_object_agg(a.attname, NULL::int))),
         -- Columns that become nested json (json, composite, arrays, hstore, domains over them):
         -- walked for sensitive keys.
         COALESCE(array_agg(a.attname::text) FILTER (
           WHERE NOT ezlogs.is_sensitive_key(a.attname)
             AND (bt.typname IN ('json', 'jsonb', 'hstore') OR bt.typtype = 'c' OR bt.typcategory = 'A')), '{}')
    INTO secret, cols, jcols
    FROM pg_attribute a
    JOIN pg_type t ON t.oid = a.atttypid
    JOIN pg_type bt ON bt.oid = CASE WHEN t.typtype = 'd' THEN t.typbasetype ELSE t.oid END
   WHERE a.attrelid = target AND a.attnum > 0 AND NOT a.attisdropped;

  argv := ARRAY[COALESCE(pk, ''), secret::text, cols::text, ezlogs.patterns_version(), rel.relname, jcols::text];

  -- Already attached with exactly these arguments: leave it (no lock, no catalog churn).
  -- Compared on the stored function and raw arguments (tgargs: each argument + a zero byte).
  IF EXISTS (SELECT 1 FROM pg_trigger t
              WHERE t.tgname = 'ezlogs_capture' AND t.tgrelid = target
                AND t.tgfoid = 'ezlogs.capture_row'::regproc
                AND t.tgargs = (SELECT string_agg(convert_to(a, 'UTF8') || '\x00'::bytea, ''::bytea ORDER BY n)
                                  FROM unnest(argv) WITH ORDINALITY AS u(a, n))) THEN
    RETURN true;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'ezlogs_capture' AND tgrelid = target) THEN
    EXECUTE format('DROP TRIGGER ezlogs_capture ON %s', target);
  END IF;
  EXECUTE format('CREATE TRIGGER ezlogs_capture AFTER INSERT OR UPDATE OR DELETE ON %s '
                 'FOR EACH ROW EXECUTE FUNCTION ezlogs.capture_row(%s)', target,
                 (SELECT string_agg(quote_literal(a), ', ' ORDER BY n) FROM unnest(argv) WITH ORDINALITY AS u(a, n)));
  RETURN true;
END;
$$;

-- For people: record a table again (also one ezlogs.skipped() leaves out by name).
CREATE OR REPLACE FUNCTION ezlogs.track(target regclass) RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
BEGIN
  DELETE FROM ezlogs.excluded WHERE table_oid = target;
  RETURN ezlogs.attach(target, by_person => true);
END;
$$;

-- For people: stop recording a table, for good (until ezlogs.track). Survives renames.
-- Name a table's rows by one of its columns, for a table with no name, title, number or label
-- column (those already name rows): select ezlogs.name_records('public.invoices', 'number');
-- A NULL column goes back to the default. Refuses a table or column that doesn't exist, and a
-- column named like a secret (never sent, so it can't name anything). Safe in a migration:
--   DO $$ BEGIN IF to_regprocedure('ezlogs.name_records(text,text)') IS NOT NULL
--     AND to_regclass('public.invoices') IS NOT NULL THEN
--     PERFORM ezlogs.name_records('public.invoices', 'number'); END IF; END $$;
CREATE OR REPLACE FUNCTION ezlogs.name_records(target text, column_name text) RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  t   regclass := to_regclass(target);
  rel pg_class%ROWTYPE;
BEGIN
  IF t IS NULL THEN
    RAISE EXCEPTION 'ezlogs.name_records: there is no table %', target
      USING HINT = 'Write it as schema.table, for example ''public.invoices''.';
  END IF;
  SELECT * INTO rel FROM pg_class WHERE oid = t;
  -- The tables EZLogs records (as ezlogs.attach): the app's own, in public, never one partition.
  IF rel.relnamespace <> 'public'::regnamespace OR rel.relkind NOT IN ('r', 'p') OR rel.relispartition THEN
    RAISE EXCEPTION 'ezlogs.name_records: % is not one of the app''s tables EZLogs records (a table in public)', t;
  END IF;
  IF column_name IS NULL THEN
    DELETE FROM ezlogs.record_names WHERE table_oid = t;
    PERFORM ezlogs.refresh_record_names();
    RETURN format('%s rows are named by their default columns again (name, title, number, label)', t);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_attribute
                  WHERE attrelid = t AND attname = column_name AND attnum > 0 AND NOT attisdropped) THEN
    RAISE EXCEPTION 'ezlogs.name_records: % has no column %', t, column_name;
  END IF;
  -- EZLogs takes plain names only (letters, digits, _), so a setting never silently names nothing.
  IF rel.relname !~ '^[A-Za-z_][A-Za-z0-9_$]{0,62}$' OR column_name !~ '^[A-Za-z_][A-Za-z0-9_$]{0,62}$' THEN
    RAISE EXCEPTION 'ezlogs.name_records: EZLogs names rows only by a plain table and column name (letters, digits and _)';
  END IF;
  IF ezlogs.is_sensitive_key(column_name) THEN
    RAISE EXCEPTION 'ezlogs.name_records: % is named like a secret, so EZLogs never receives it and it can''t name rows', column_name;
  END IF;
  INSERT INTO ezlogs.record_names (table_oid, column_name) VALUES (t, column_name)
    ON CONFLICT (table_oid) DO UPDATE SET column_name = EXCLUDED.column_name;
  PERFORM ezlogs.refresh_record_names();
  RETURN format('%s rows are named by %s', t, column_name);
END;
$$;

-- {"public.invoices": "number"}, for the tables that still exist (at most 200).
CREATE OR REPLACE FUNCTION ezlogs.record_names_json() RETURNS jsonb
  LANGUAGE sql STABLE
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
  SELECT COALESCE(jsonb_object_agg(k, v), '{}'::jsonb) FROM (
    SELECT n.nspname || '.' || c.relname AS k, r.column_name AS v
      FROM ezlogs.record_names r
      JOIN pg_class c ON c.oid = r.table_oid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     ORDER BY 1 LIMIT 200) named;
$$;

-- Copy the names to ezlogs.state (by current table name: a rename is a schema change, which
-- refreshes them). Never called while the app writes.
CREATE OR REPLACE FUNCTION ezlogs.refresh_record_names() RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
  UPDATE ezlogs.state SET record_names = ezlogs.record_names_json() WHERE one;
$$;

CREATE OR REPLACE FUNCTION ezlogs.untrack(target regclass) RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
BEGIN
  INSERT INTO ezlogs.excluded (table_oid) VALUES (target) ON CONFLICT DO NOTHING;
  EXECUTE format('DROP TRIGGER IF EXISTS ezlogs_capture ON %s', target);
END;
$$;

-- Track every public table (new ones, and ones whose columns changed). Runs at connect, on
-- schema changes, and from the flush job at most every 10 minutes. Nothing before connect().
-- Supabase's own tables (accounts, sessions, files), each when it exists. Called by connect and by
-- reconcile, so re-applying this file to upgrade also adds a table a newer version reads.
CREATE OR REPLACE FUNCTION ezlogs.attach_platform() RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
BEGIN
  -- Each table on its own: one that can't be tracked now never undoes the others.
  BEGIN
    IF to_regclass('auth.users') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'ezlogs_capture' AND tgrelid = 'auth.users'::regclass) THEN
      CREATE TRIGGER ezlogs_capture AFTER INSERT OR UPDATE OR DELETE ON auth.users
        FOR EACH ROW EXECUTE FUNCTION ezlogs.capture_auth_user();
    END IF;
  EXCEPTION WHEN others THEN
    RAISE WARNING '[ezlogs] could not track auth.users now (retried later): %', SQLERRM;
  END;
  BEGIN
    IF to_regclass('storage.objects') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'ezlogs_capture' AND tgrelid = 'storage.objects'::regclass) THEN
      CREATE TRIGGER ezlogs_capture AFTER INSERT OR UPDATE OR DELETE ON storage.objects
        FOR EACH ROW EXECUTE FUNCTION ezlogs.capture_storage_object();
    END IF;
  EXCEPTION WHEN others THEN
    RAISE WARNING '[ezlogs] could not track storage.objects now (retried later): %', SQLERRM;
  END;
  BEGIN
    IF to_regclass('auth.sessions') IS NOT NULL
       AND has_table_privilege('auth.sessions', 'TRIGGER')
       AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'ezlogs_capture' AND tgrelid = 'auth.sessions'::regclass) THEN
      -- People already signed in keep their session for weeks: send the newest sessions once (id and
      -- user only, at most 20,000). Read before the trigger exists, so the read holds up no sign-in;
      -- the trigger's lock then lasts until this transaction commits (well under a second). A
      -- sign-in that commits between the read and the trigger is missed: that person is named again
      -- from their next sign-in.
      INSERT INTO ezlogs.outbox (schema_name, table_name, op, old_row, new_row, resource_id)
      SELECT 'auth', 'sessions', 'INSERT', NULL,
             jsonb_strip_nulls(jsonb_build_object('id', se.id, 'user_id', se.user_id, 'created_at', se.created_at)), se.id::text
        FROM auth.sessions se
       ORDER BY se.created_at DESC NULLS LAST
       LIMIT 20000;
      CREATE TRIGGER ezlogs_capture AFTER INSERT ON auth.sessions
        FOR EACH ROW EXECUTE FUNCTION ezlogs.capture_auth_session();
    END IF;
  EXCEPTION WHEN others THEN
    RAISE WARNING '[ezlogs] could not track auth.sessions now (retried later): %', SQLERRM;
  END;
END;
$$;

CREATE OR REPLACE FUNCTION ezlogs.reconcile() RETURNS int
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  t regclass;
  n int := 0;
BEGIN
  IF NOT ezlogs.connected() THEN
    RETURN 0;
  END IF;
  PERFORM ezlogs.attach_platform();
  FOR t IN SELECT c.oid::regclass FROM pg_class c
            WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p') AND NOT c.relispartition
  LOOP
    BEGIN
      IF ezlogs.attach(t) THEN n := n + 1; END IF;
    EXCEPTION WHEN others THEN
      RAISE WARNING '[ezlogs] could not track % now (retried later): %', t, SQLERRM;
    END;
  END LOOP;
  UPDATE ezlogs.state SET last_reconciled = now() WHERE one;
  RETURN n;
END;
$$;

-- New and altered tables are tracked as soon as the migration creates them.
CREATE OR REPLACE FUNCTION ezlogs.on_ddl() RETURNS event_trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  r record;
BEGIN
  IF NOT ezlogs.connected() THEN
    RETURN;
  END IF;
  FOR r IN SELECT objid FROM pg_event_trigger_ddl_commands()
            WHERE command_tag IN ('CREATE TABLE', 'ALTER TABLE', 'CREATE TABLE AS', 'SELECT INTO')
              AND object_type = 'table' AND schema_name = 'public'
  LOOP
    PERFORM ezlogs.attach(r.objid::regclass);
  END LOOP;
  -- A renamed table keeps its name setting under its new name. Its own block: a failure here
  -- never undoes the tracking above.
  BEGIN
    IF EXISTS (SELECT 1 FROM ezlogs.record_names) THEN
      PERFORM ezlogs.refresh_record_names();
    END IF;
  EXCEPTION WHEN others THEN
    RAISE WARNING '[ezlogs] could not refresh record names (the next name_records does): %', SQLERRM;
  END;
EXCEPTION WHEN others THEN
  RAISE WARNING '[ezlogs] could not track a new table (it is picked up later): %', SQLERRM;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'ezlogs_track_tables') THEN
    CREATE EVENT TRIGGER ezlogs_track_tables ON ddl_command_end EXECUTE FUNCTION ezlogs.on_ddl();
  END IF;
EXCEPTION WHEN others THEN
  -- Not every host lets this role create event triggers; the flush job's reconcile covers it.
  RAISE NOTICE '[ezlogs] event trigger not available (%); new tables are picked up by the flush job', SQLERRM;
END $$;

-- ---------------------------------------------------------------------------------------
-- Shipping
-- ---------------------------------------------------------------------------------------

-- Post one batch of unsent rows: oldest first, read through the unsent index only, up to 500
-- rows and 48 KB of row data. pg_net (0.20) stalls on request bodies over ~64 KB (it sends the
-- first 64 KB and waits until the timeout), so posts stay well under that. A transaction
-- bigger than one post spans several; EZLogs joins its rows. The caller holds the state row.
-- One outbox row as it is posted (send_batch measures and sends exactly this).
CREATE OR REPLACE FUNCTION ezlogs.row_json(o ezlogs.outbox) RETURNS jsonb
  LANGUAGE sql STABLE
AS $$
  SELECT jsonb_build_object(
    'id', o.id, 'schema', o.schema_name, 'table', o.table_name, 'op', o.op,
    'old', o.old_row, 'new', o.new_row, 'resource_id', o.resource_id,
    'claims', o.claims, 'correlation_id', o.correlation_id, 'txid', o.txid,
    'tx_started_at', o.tx_started_at, 'captured_at', o.captured_at)
$$;

CREATE OR REPLACE FUNCTION ezlogs.send_batch() RETURNS int
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  st      ezlogs.state%ROWTYPE;
  key     text;
  ids     bigint[];
  payload jsonb;
  rid     bigint;
  names   jsonb;
BEGIN
  SELECT * INTO st FROM ezlogs.state WHERE one;
  IF st.connected_at IS NULL OR (st.paused_until IS NOT NULL AND st.paused_until > clock_timestamp()) THEN
    RETURN 0;
  END IF;
  SELECT decrypted_secret INTO key FROM vault.decrypted_secrets WHERE name = 'ezlogs_ingest_key' LIMIT 1;
  IF key IS NULL THEN
    RETURN 0;
  END IF;

  -- The names ride in every post (read from state, already loaded): their bytes come out of the
  -- rows' 48 KB. When even the oldest row fits only alone, that post goes without names.
  names := st.record_names;
  LOOP
    SELECT array_agg(id ORDER BY id) INTO ids FROM (
      SELECT c.id, c.bytes, sum(c.bytes) OVER (ORDER BY c.id) AS running
        FROM (SELECT o.id, octet_length(ezlogs.row_json(o)::text) + 2 AS bytes
                FROM ezlogs.outbox o WHERE o.request_id IS NULL ORDER BY o.id LIMIT 500) c) s
     WHERE s.running <= 49152 - octet_length(names::text);
    EXIT WHEN ids IS NOT NULL OR names = '{}'::jsonb;
    names := '{}'::jsonb;
  END LOOP;
  IF ids IS NULL THEN
    -- The oldest row alone is over the limit (enqueue keeps rows under 41 KB, so only a row
    -- written by an older version can be): drop and count it rather than block everything.
    WITH gone AS (
      DELETE FROM ezlogs.outbox WHERE id = (SELECT id FROM ezlogs.outbox WHERE request_id IS NULL ORDER BY id LIMIT 1)
      RETURNING 1)
    UPDATE ezlogs.state SET dropped_total = dropped_total + (SELECT count(*) FROM gone) WHERE one;
    RETURN 0;
  END IF;

  SELECT jsonb_build_object(
           'install_id',   st.install_id,
           'version',      ezlogs.version(),
           'supabase_url', st.supabase_url,
           'dropped_rows', st.dropped_total,
           'names',        names,
           'rows', jsonb_agg(ezlogs.row_json(o) ORDER BY o.id))
    INTO payload
    FROM ezlogs.outbox o WHERE o.id = ANY(ids);

  SELECT net.http_post(
           url                  := ezlogs.endpoint(),
           body                 := payload,
           headers              := jsonb_build_object('Authorization', 'Bearer ' || key,
                                                      'Content-Type', 'application/json'),
           timeout_milliseconds := 10000)
    INTO rid;

  UPDATE ezlogs.outbox SET request_id = rid, sent_at = clock_timestamp() WHERE id = ANY(ids);
  UPDATE ezlogs.state SET last_sent_at = clock_timestamp() WHERE one;
  RETURN array_length(ids, 1);
END;
$$;

-- The flush job exists only while rows wait or await confirmation. Scheduled only by the
-- transaction holding the state row, so writers never wait on each other here.
CREATE OR REPLACE FUNCTION ezlogs.ensure_flush_job() RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
BEGIN
  IF to_regclass('cron.job') IS NULL OR EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ezlogs-flush')
     -- Paused for something only a person can fix: the next write after the pause wakes it.
     OR EXISTS (SELECT 1 FROM ezlogs.state WHERE one AND paused_until > clock_timestamp() + interval '10 minutes') THEN
    RETURN;
  END IF;
  PERFORM cron.schedule('ezlogs-flush', '5 seconds', 'SELECT ezlogs.flush()');
END;
$$;

-- Runs once per writing transaction, at commit (a deferred constraint trigger on the outbox).
-- Bounded: if no other transaction is shipping and a second has passed, post one batch (at
-- most 500 rows read in id order through the unsent index); then make sure the flush job
-- exists to confirm it. Never raises, never waits for a lock. A SERIALIZABLE transaction ships
-- nothing itself: its rows go with the next other write or a running flush job (an app whose
-- every write is SERIALIZABLE should run `select ezlogs.ensure_flush_job()` after writes).
CREATE OR REPLACE FUNCTION ezlogs.ship_at_commit() RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
  SET lock_timeout = '50ms'
AS $$
DECLARE
  st ezlogs.state%ROWTYPE;
BEGIN
  IF current_setting('ezlogs.shipped_tx', true) = txid_current()::text THEN
    RETURN NULL;
  END IF;
  PERFORM set_config('ezlogs.shipped_tx', txid_current()::text, true);
  -- A SERIALIZABLE transaction would take on our reads as conflicts: leave its rows to the
  -- next writer or the flush job.
  IF current_setting('transaction_isolation') = 'serializable' THEN
    RETURN NULL;
  END IF;
  SELECT * INTO st FROM ezlogs.state WHERE one FOR UPDATE SKIP LOCKED;
  IF NOT FOUND OR st.connected_at IS NULL THEN
    RETURN NULL;
  END IF;
  IF st.last_sent_at IS NULL OR st.last_sent_at < clock_timestamp() - interval '1 second' THEN
    PERFORM ezlogs.send_batch();
  END IF;
  PERFORM ezlogs.ensure_flush_job();
  RETURN NULL;
EXCEPTION
  WHEN query_canceled THEN
    -- The app's own statement timeout firing during our part: give up our part, keep its commit.
    RETURN NULL;
  WHEN others THEN
    RAISE WARNING '[ezlogs] ship at commit failed (rows stay queued): %', SQLERRM;
    RETURN NULL;
END;
$$;

DO $$
BEGIN
  -- Recreating it would lock the outbox (and every tracked write) during an upgrade.
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'ezlogs_ship_at_commit' AND tgrelid = 'ezlogs.outbox'::regclass) THEN
    CREATE CONSTRAINT TRIGGER ezlogs_ship_at_commit AFTER INSERT ON ezlogs.outbox
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ezlogs.ship_at_commit();
  END IF;
END $$;

-- The flush job, every 5 seconds while it exists: read EZLogs' replies, retry what failed,
-- keep the outbox bounded, pick up new tables, send what is waiting, and remove itself once
-- nothing is waiting or shipping is paused for something only a person can fix.
CREATE OR REPLACE FUNCTION ezlogs.flush() RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
  SET lock_timeout = '2s'
AS $$
DECLARE
  st      ezlogs.state%ROWTYPE;
  resp    record;
  dropped bigint;
  i       int;
BEGIN
  SELECT * INTO st FROM ezlogs.state WHERE one FOR UPDATE;

  -- 0. pg_net's request ids restart after a database restart: rows sent before it can never
  --    be matched to a reply safely, so they go again (EZLogs drops the duplicates).
  UPDATE ezlogs.outbox SET request_id = NULL, sent_at = NULL
   WHERE request_id IS NOT NULL AND sent_at < pg_postmaster_start_time();

  -- 1. Replies, oldest first, so the newest decides the state. A reply only counts for rows
  --    sent before it. Read through the reply table's index on created.
  FOR resp IN
    SELECT r.id, r.status_code, r.timed_out, r.error_msg, r.created
      FROM net._http_response r
     WHERE r.created >= (SELECT min(sent_at) FROM ezlogs.outbox WHERE request_id IS NOT NULL)
       AND r.id IN (SELECT DISTINCT request_id FROM ezlogs.outbox WHERE request_id IS NOT NULL)
     ORDER BY r.created
  LOOP
    IF resp.status_code BETWEEN 200 AND 299 THEN
      DELETE FROM ezlogs.outbox WHERE request_id = resp.id AND sent_at <= resp.created;
      UPDATE ezlogs.state SET last_status = resp.status_code, last_error = NULL, failures = 0, paused_until = NULL
       WHERE one;
    ELSIF resp.status_code IN (400, 413, 422) THEN
      -- Refused for good: retrying the same rows would block everything behind them.
      WITH gone AS (DELETE FROM ezlogs.outbox WHERE request_id = resp.id AND sent_at <= resp.created RETURNING 1)
      UPDATE ezlogs.state SET dropped_total = dropped_total + (SELECT count(*) FROM gone),
                              last_status = resp.status_code, last_error = 'EZLogs refused a batch (HTTP ' || resp.status_code || ')'
       WHERE one;
    ELSIF st.connected_at IS NOT NULL AND EXISTS (SELECT 1 FROM ezlogs.outbox
                       WHERE request_id = resp.id AND sent_at <= resp.created AND sent_at < st.connected_at) THEN
      -- Sent before the last connect() (a revoked key reconnected): send its rows again, but this
      -- answer was for the old connection and never pauses the new one.
      UPDATE ezlogs.outbox SET request_id = NULL, sent_at = NULL WHERE request_id = resp.id AND sent_at <= resp.created;
    ELSE
      UPDATE ezlogs.outbox SET request_id = NULL, sent_at = NULL WHERE request_id = resp.id AND sent_at <= resp.created;
      UPDATE ezlogs.state
         SET last_status = resp.status_code,
             last_error  = left(COALESCE(resp.error_msg, CASE WHEN resp.timed_out THEN 'timed out' END,
                                         'HTTP ' || resp.status_code), 300),
             failures    = failures + 1,
             -- Key revoked / account stopped: an hour. Rate limited: 5 minutes.
             -- Anything else: back off 2^failures seconds, at most 10 minutes.
             paused_until = clock_timestamp() + CASE
               WHEN resp.status_code IN (401, 402, 403, 423) THEN interval '1 hour'
               WHEN resp.status_code = 429 THEN interval '5 minutes'
               ELSE least(interval '10 minutes', make_interval(secs => power(2, least(failures + 1, 10))))
             END
       WHERE one;
    END IF;
  END LOOP;

  -- 2. A request pg_net lost (its queue is unlogged) never gets a reply: retry after 2 minutes.
  UPDATE ezlogs.outbox o SET request_id = NULL, sent_at = NULL
   WHERE o.request_id IS NOT NULL AND o.sent_at < clock_timestamp() - interval '2 minutes'
     AND NOT EXISTS (SELECT 1 FROM net._http_response r WHERE r.id = o.request_id AND r.created >= o.sent_at)
     AND NOT EXISTS (SELECT 1 FROM net.http_request_queue q WHERE q.id = o.request_id);

  -- 3. Bounded outbox: at most 500,000 rows, none older than 7 days. Ids grow with time, so
  --    both are id ranges (primary key), never a scan.
  WITH gone AS (
    DELETE FROM ezlogs.outbox WHERE id < (SELECT max(id) - 500000 FROM ezlogs.outbox) RETURNING 1)
  SELECT count(*) INTO dropped FROM gone;
  FOR i IN 1..10 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM (SELECT captured_at FROM ezlogs.outbox ORDER BY id LIMIT 1) h
                           WHERE h.captured_at < clock_timestamp() - interval '7 days');
    WITH gone AS (
      DELETE FROM ezlogs.outbox WHERE id IN (SELECT id FROM ezlogs.outbox ORDER BY id LIMIT 10000)
                                  AND captured_at < clock_timestamp() - interval '7 days' RETURNING 1)
    SELECT dropped + count(*) INTO dropped FROM gone;
  END LOOP;
  IF dropped > 0 THEN
    UPDATE ezlogs.state SET dropped_total = dropped_total + dropped WHERE one;
  END IF;

  -- 4. Every 10 minutes: new or changed tables (when the host has no event trigger), and the
  --    job's own run history (it would grow by 17,000 rows a day while the job runs).
  IF st.last_reconciled IS NULL OR st.last_reconciled < clock_timestamp() - interval '10 minutes' THEN
    PERFORM ezlogs.reconcile();
    BEGIN
      DELETE FROM cron.job_run_details
       WHERE jobid IN (SELECT jobid FROM cron.job WHERE jobname = 'ezlogs-flush')
         AND end_time < now() - interval '1 hour';
    EXCEPTION WHEN others THEN
      NULL;
    END;
  END IF;

  -- 5. Send what waits: up to 10 small posts this run (about 1,000 rows every 5 seconds).
  FOR i IN 1..10 LOOP
    EXIT WHEN ezlogs.send_batch() = 0;
  END LOOP;

  -- 6. Remove the job when nothing waits, when not connected, or when paused for a person.
  --    (A write that commits right after this check waits for the next write to ship.)
  SELECT * INTO st FROM ezlogs.state WHERE one;
  IF NOT EXISTS (SELECT 1 FROM ezlogs.outbox)
     OR st.connected_at IS NULL
     OR st.paused_until > clock_timestamp() + interval '10 minutes' THEN
    PERFORM cron.unschedule('ezlogs-flush');
  END IF;
EXCEPTION WHEN others THEN
  RAISE WARNING '[ezlogs] flush failed: %', SQLERRM;
END;
$$;

-- ---------------------------------------------------------------------------------------
-- Connect, status, uninstall
-- ---------------------------------------------------------------------------------------

-- Run once in the SQL editor with the database key from EZLogs (the install code EZLogs gives
-- you ends with this line, key filled in). The project URL is optional.
DROP FUNCTION IF EXISTS ezlogs.connect(text, text);
CREATE OR REPLACE FUNCTION ezlogs.connect(p_key text, p_supabase_url text DEFAULT NULL) RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  url       text := NULLIF(rtrim(trim(p_supabase_url), '/'), '');
  secret_id uuid;
BEGIN
  IF p_key IS NULL OR p_key !~ '^ezldb_[A-Za-z0-9_-]{20,}$' THEN
    RAISE EXCEPTION 'That is not an EZLogs database key (they start with ezldb_). Copy the install code from EZLogs: Settings, API keys, the Lovable · Bolt · v0 tab. A key that starts with ezl_ is for the Rails or Next.js agent, not for a database.';
  END IF;
  IF to_regclass('vault.secrets') IS NULL THEN
    RAISE EXCEPTION 'Supabase Vault is not installed in this database; EZLogs keeps its key there.';
  END IF;
  IF to_regclass('cron.job') IS NULL THEN
    RAISE EXCEPTION 'EZLogs needs the pg_cron extension (Database, Extensions, pg_cron) to confirm deliveries.';
  END IF;
  IF to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') IS NULL THEN
    RAISE EXCEPTION 'EZLogs needs the pg_net extension (Database, Extensions, pg_net) to send changes.';
  END IF;
  IF url IS NOT NULL AND url !~ '^https://[a-z0-9-]+\.(supabase\.co|lovable\.cloud)$' THEN
    RAISE EXCEPTION 'Use the project URL, like https://abcd.supabase.co (Lovable Cloud: the VITE_SUPABASE_URL value).';
  END IF;

  SELECT id INTO secret_id FROM vault.secrets WHERE name = 'ezlogs_ingest_key';
  IF secret_id IS NULL THEN
    PERFORM vault.create_secret(p_key, 'ezlogs_ingest_key', 'EZLogs database key (ingest only)');
  ELSE
    PERFORM vault.update_secret(secret_id, p_key);
  END IF;

  UPDATE ezlogs.state
     SET supabase_url = COALESCE(url, supabase_url), connected_at = now(), paused_until = NULL, failures = 0, last_error = NULL
   WHERE one;

  PERFORM ezlogs.attach_platform();

  PERFORM ezlogs.reconcile();
  IF EXISTS (SELECT 1 FROM ezlogs.outbox) THEN
    PERFORM ezlogs.ensure_flush_job();
  END IF;

  -- Say hello: an empty post, so EZLogs shows this database as connected before the app writes.
  UPDATE ezlogs.state s
     SET hello_request_id = net.http_post(
           url                  := ezlogs.endpoint(),
           body                 := jsonb_build_object('install_id', s.install_id, 'version', ezlogs.version(),
                                                      'supabase_url', s.supabase_url, 'dropped_rows', s.dropped_total,
                                                      'rows', '[]'::jsonb),
           headers              := jsonb_build_object('Authorization', 'Bearer ' || p_key, 'Content-Type', 'application/json'),
           timeout_milliseconds := 10000)
   WHERE one;

  RETURN format('Connected (EZLogs %s). Now recording changes to %s tables, sign-ups, sign-ins and files.',
                ezlogs.version(),
                (SELECT count(*) FROM pg_trigger WHERE tgname = 'ezlogs_capture' AND NOT tgisinternal
                   AND tgrelid IN (SELECT oid FROM pg_class WHERE relnamespace = 'public'::regnamespace)));
END;
$$;

-- What the install page and a person debugging need. Works whatever is missing.
CREATE OR REPLACE FUNCTION ezlogs.status() RETURNS jsonb
  LANGUAGE plpgsql STABLE
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  s     ezlogs.state%ROWTYPE;
  hello text;
BEGIN
  SELECT * INTO s FROM ezlogs.state WHERE one;
  IF to_regclass('net._http_response') IS NULL THEN
    hello := 'pg_net not installed';
  ELSIF s.hello_request_id IS NOT NULL THEN
    -- EZLogs' answer to connect()'s hello: 202 = connected; 401 = wrong or revoked key.
    EXECUTE 'SELECT COALESCE(status_code::text, error_msg) FROM net._http_response WHERE id = $1'
       INTO hello USING s.hello_request_id;
  END IF;
  RETURN jsonb_build_object(
    'version',        ezlogs.version(),
    'connected',      s.connected_at IS NOT NULL,
    'supabase_url',   s.supabase_url,
    'waiting_rows',   (SELECT count(*) FROM ezlogs.outbox),
    'tracked_tables', (SELECT count(*) FROM pg_trigger WHERE tgname = 'ezlogs_capture' AND NOT tgisinternal),
    'last_sent_at',   s.last_sent_at,
    'last_status',    s.last_status,
    'last_error',     s.last_error,
    'paused_until',   s.paused_until,
    'dropped_total',  s.dropped_total,
    'flush_job',      CASE WHEN to_regclass('cron.job') IS NULL THEN 'pg_cron not installed' END,
    'hello',          hello,
    'record_names',   s.record_names);
END;
$$;

CREATE OR REPLACE FUNCTION ezlogs.uninstall() RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT tgrelid::regclass AS rel FROM pg_trigger WHERE tgname = 'ezlogs_capture' AND NOT tgisinternal LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS ezlogs_capture ON %s', r.rel);
  END LOOP;
  DROP EVENT TRIGGER IF EXISTS ezlogs_track_tables;
  IF to_regclass('cron.job') IS NOT NULL AND EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ezlogs-flush') THEN
    PERFORM cron.unschedule('ezlogs-flush');
  END IF;
  DELETE FROM vault.secrets WHERE name = 'ezlogs_ingest_key';
  DROP SCHEMA ezlogs CASCADE;
  RETURN 'EZLogs removed: triggers, job, key and the ezlogs schema are gone.';
END;
$$;

-- Re-applying this file keeps the names each post carries in step with ezlogs.record_names.
SELECT ezlogs.refresh_record_names();

-- Nothing in this schema is callable by the API roles. The capture and ship functions run
-- from triggers as their owner; connect / status / uninstall are for the SQL editor.
DO $$
DECLARE r text;
BEGIN
  REVOKE ALL ON ALL TABLES IN SCHEMA ezlogs FROM PUBLIC;
  REVOKE ALL ON ALL SEQUENCES IN SCHEMA ezlogs FROM PUBLIC;
  REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ezlogs FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA ezlogs FROM %I', r);
      EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA ezlogs FROM %I', r);
      EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ezlogs FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- Already connected (re-applying the migration to upgrade): refresh the triggers now.
SELECT ezlogs.reconcile();

RESET check_function_bodies;
