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
--   * on every table in `public` (new tables are picked up): capture once per statement (three
--     statement triggers and functions made for that table; a table without a one-column key has
--     one row trigger), on auth.users (sign-ups, sign-ins, account changes), on auth.sessions (a
--     new session's id and user only) and on storage.objects (files), writing into ezlogs.outbox
--     with sensitive and ignored columns removed (inside json too) and large values replaced by
--     their size; an update carries what changed; a statement over 100 rows is one bulk row;
--   * who did it comes from the login Supabase already verified (request.jwt.claims);
--   * when a writing transaction commits, at most once a second, the database posts what is
--     waiting to EZLogs with pg_net; rows leave the outbox only after EZLogs confirmed them;
--   * a pg_cron job (`ezlogs-flush`) exists only while rows wait or await confirmation, and
--     removes itself, so an idle project runs nothing of ours and still pauses normally.
--
-- Guarantees:
--   * it never blocks or breaks a write: per-statement work is one bounded insert that swallows
--     its own errors; the work at commit is bounded, index-only, takes no lock anyone waits for
--     and swallows its own errors; everything else (confirmations, cleanup, attaching tables)
--     runs in the flush job, with short lock timeouts;
--   * it never fills the database: past 50 MB waiting (or 5% of the database) capture pauses
--     until the outbox drains to half;
--   * nothing here is reachable through Supabase's HTTP API (own schema, no grants);
--   * data only ever goes to app.ezlogs.io (hard-coded, not a setting);
--   * the key lives in Supabase Vault (readable there by the database owner and service_role,
--     as every Vault secret is; it is an ingest-only key that can never read data back).
--
-- Limits: about 45,000 changed rows a minute shipped (posts stay under 48 KB: pg_net stalls on
-- bigger bodies); past 500,000 waiting rows or 7 days the oldest are dropped (and counted).
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

-- Re-applying this file (an upgrade) must never take a lock on a table every captured write
-- uses unless something is really missing: ALTER TABLE ... ADD COLUMN IF NOT EXISTS and CREATE
-- INDEX IF NOT EXISTS lock the table even when there is nothing to do. These check the catalog
-- first, and wait at most half a second for the lock when a change is needed (the install then
-- stops with a message; run it again), so the app's writes never queue behind it for long.
CREATE OR REPLACE FUNCTION ezlogs.ensure_column(tbl text, col text, def text) RETURNS void
  LANGUAGE plpgsql
AS $$
DECLARE
  prev text := current_setting('lock_timeout');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = tbl::regclass AND attname = col AND attnum > 0 AND NOT attisdropped) THEN
    PERFORM set_config('lock_timeout', '500ms', true);
    EXECUTE format('ALTER TABLE %s ADD COLUMN IF NOT EXISTS %I %s', tbl, col, def);
    PERFORM set_config('lock_timeout', prev, true);
  END IF;
EXCEPTION WHEN lock_not_available THEN
  RAISE EXCEPTION '[ezlogs] % is busy right now, so this upgrade stopped without changing anything. Run it again in a moment.', tbl;
END;
$$;

CREATE OR REPLACE FUNCTION ezlogs.ensure_index(name text, ddl text) RETURNS void
  LANGUAGE plpgsql
AS $$
DECLARE
  prev text := current_setting('lock_timeout');
BEGIN
  IF to_regclass('ezlogs.' || quote_ident(name)) IS NULL THEN
    PERFORM set_config('lock_timeout', '500ms', true);
    EXECUTE ddl;
    PERFORM set_config('lock_timeout', prev, true);
  END IF;
EXCEPTION WHEN lock_not_available THEN
  RAISE EXCEPTION '[ezlogs] the outbox is busy right now, so this upgrade stopped without changing anything. Run it again in a moment.';
END;
$$;

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
-- A statement over ezlogs.bulk_threshold() rows is one row here (1.5.0): how many, and what it set.
SELECT ezlogs.ensure_column('ezlogs.outbox', 'row_count', 'int');
SELECT ezlogs.ensure_column('ezlogs.outbox', 'bulk', 'jsonb');
SELECT ezlogs.ensure_index('outbox_unsent_idx', 'CREATE INDEX IF NOT EXISTS outbox_unsent_idx ON ezlogs.outbox (id) WHERE request_id IS NULL');
SELECT ezlogs.ensure_index('outbox_request_idx', 'CREATE INDEX IF NOT EXISTS outbox_request_idx ON ezlogs.outbox (request_id) WHERE request_id IS NOT NULL');

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
SELECT ezlogs.ensure_column('ezlogs.state', 'hello_request_id', 'bigint');
-- {"public.invoices": "reference"}: ezlogs.record_names as each post sends it, kept here so sending
-- (which also runs at commit) reads no other table. Refreshed by name_records and schema changes.
SELECT ezlogs.ensure_column('ezlogs.state', 'record_names', 'jsonb NOT NULL DEFAULT ''{}''::jsonb');
-- Capture paused so the outbox can never fill the database (1.5.0): since when and why
-- ('outbox full', or 'EZLogs refused for an hour: <reason>'). The flush job resumes it.
SELECT ezlogs.ensure_column('ezlogs.state', 'capture_paused_at', 'timestamptz');
SELECT ezlogs.ensure_column('ezlogs.state', 'capture_paused_reason', 'text');
-- Since when EZLogs has refused for something only a person can fix (401, 402, 403, 423).
SELECT ezlogs.ensure_column('ezlogs.state', 'blocked_since', 'timestamptz');
-- The outbox's size cap in bytes, measured at reconcile: 50 MB or 5% of the database, the smaller.
SELECT ezlogs.ensure_column('ezlogs.state', 'outbox_cap_bytes', 'bigint');
INSERT INTO ezlogs.state (one) VALUES (true) ON CONFLICT DO NOTHING;

-- Tables a person took out with ezlogs.untrack(); nothing puts them back but ezlogs.track().
CREATE TABLE IF NOT EXISTS ezlogs.excluded (table_oid oid PRIMARY KEY);

-- Tables a person recorded with ezlogs.track() though their name is one EZLogs skips.
CREATE TABLE IF NOT EXISTS ezlogs.tracked (table_oid oid PRIMARY KEY);

-- The column a person recognises a table's rows by, set with ezlogs.name_records() when the
-- table has no name, title, number or label column. Copied to ezlogs.state.record_names, which
-- each post carries: EZLogs names each row from that column of the row it already got.
CREATE TABLE IF NOT EXISTS ezlogs.record_names (table_oid oid PRIMARY KEY, column_name text NOT NULL);

-- Columns a person told EZLogs to leave out (ezlogs.ignore_columns): a heartbeat such as
-- last_seen_at. Never sent; an update that changed only these is not recorded.
CREATE TABLE IF NOT EXISTS ezlogs.ignored_columns (table_oid oid PRIMARY KEY, columns text[] NOT NULL);

-- One row per writing transaction (1.5.0): its deferred trigger ships at commit, once, however
-- many rows the transaction wrote. Cleared at commit and by the flush job.
CREATE TABLE IF NOT EXISTS ezlogs.tx_marks (
  txid      bigint      PRIMARY KEY DEFAULT txid_current(),
  marked_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION ezlogs.version() RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT '1.5.2' $$;

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
  SELECT s ~ '(password|token|secret|api_key|credit_card|ssn|social_security|encrypted|private_key|public_key|signing_key|pem|cipher|nonce|salt|digest|signature|hmac|credential|passwd|passcode|apikey|card_number|cardnumber|cvv|cvc|verification_code|recovery_code|backup_code|one_time_code|login_code)'
      OR lower(k) ~ '(password|token|secret|api_key|credit_card|ssn|social_security|encrypted|private_key|public_key|signing_key|pem|cipher|nonce|salt|digest|signature|hmac|credential|passwd|passcode|apikey|card_number|cardnumber|cvv|cvc|verification_code|recovery_code|backup_code|one_time_code|login_code)'
      OR s ~ '(^|[^a-z0-9])(pin|otp|totp|iban|mfa|passphrase|jti)([^a-z0-9]|$)'
    FROM (SELECT lower(regexp_replace(k, '([a-z0-9])([A-Z])', '\1_\2', 'g')) AS s) AS words
$$;

-- Bump whenever is_sensitive_key changes: triggers attached under another version fall back
-- to checking every key and are re-attached by the next reconcile.
CREATE OR REPLACE FUNCTION ezlogs.patterns_version() RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT 'p2' $$;

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

-- The same note from a stored size (pg_column_size), so a large value is never read.
CREATE OR REPLACE FUNCTION ezlogs.size_note(bytes int) RETURNS jsonb
  LANGUAGE sql IMMUTABLE
AS $$ SELECT to_jsonb(format('[%s bytes, not recorded]', bytes)) $$;

-- More rows than this in one statement are recorded as one bulk row (the server reads it as one
-- bulk step, like Rails' update_all), never one row each.
CREATE OR REPLACE FUNCTION ezlogs.bulk_threshold() RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 100 $$;

-- Read once per transaction (ezlogs.begin_capture): when true, nothing is recorded (see state).
CREATE OR REPLACE FUNCTION ezlogs.capture_paused() RETURNS boolean
  LANGUAGE sql STABLE
AS $$ SELECT EXISTS (SELECT 1 FROM ezlogs.state WHERE one AND capture_paused_at IS NOT NULL) $$;

-- Called by every capture before it records: true to record, false while capture is paused.
-- The first call in a transaction marks it (shipping then runs once, at its commit; while paused
-- the commit still wakes the flush job, which resumes capture) and reads the pause flag; later
-- calls in the same transaction read both from a transaction-local setting, never a table.
CREATE OR REPLACE FUNCTION ezlogs.begin_capture() RETURNS boolean
  LANGUAGE plpgsql
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  tx     text := txid_current()::text;
  cached text := current_setting('ezlogs.tx', true);
  paused boolean;
BEGIN
  IF cached LIKE tx || ':%' THEN
    RETURN cached = tx || ':record';
  END IF;
  INSERT INTO ezlogs.tx_marks (txid) VALUES (tx::bigint) ON CONFLICT DO NOTHING;
  paused := ezlogs.capture_paused();
  PERFORM set_config('ezlogs.tx', tx || CASE WHEN paused THEN ':paused' ELSE ':record' END, true);
  RETURN NOT paused;
END;
$$;

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
-- writes (sign-up, sign-in) carry none. A write with neither, made by a pg_cron job (its sessions are
-- named 'pg_cron'), says so: {"scheduler": "pg_cron"} (1.5.2). Parsed once per transaction.
CREATE OR REPLACE FUNCTION ezlogs.request_claims() RETURNS jsonb
  LANGUAGE plpgsql VOLATILE
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  raw    text := current_setting('request.jwt.claims', true);
  aid    text := NULLIF(current_setting('ezlogs.actor_id', true), '');
  app    text := current_setting('application_name', true);
  src    text := COALESCE(raw, '') || '|' || COALESCE(aid, '') || '|' || COALESCE(app, '');
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
      -- The login's session (auth.sessions id): names the person behind a browser report even when
      -- auth.sessions can't be read or the session began before the install (1.5.0).
      'session_id',   CASE WHEN c->>'session_id' ~ '^[0-9a-f-]{36}$' THEN c->>'session_id' END,
      -- The project's own auth address, from a token it signed: which Supabase project this is.
      'iss',          left(c->>'iss', 200),
      'is_anonymous', CASE WHEN jsonb_typeof(c->'is_anonymous') = 'boolean' THEN c->'is_anonymous' END
    )), '{}'::jsonb);
  ELSIF app = 'pg_cron' THEN
    result := jsonb_build_object('scheduler', 'pg_cron');
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
  IF NOT ezlogs.begin_capture() THEN
    RETURN;
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
    IF TG_NARGS >= 2 THEN   -- left-out columns too (secret-named ones are already gone)
      old_json := old_json - TG_ARGV[1]::text[];
      new_json := new_json - TG_ARGV[1]::text[];
    END IF;
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

-- 1.5.0: app tables with a one-column primary key are captured once per statement, not per row
-- (three triggers: Postgres allows a transition table only on a single-event trigger), each by a
-- function made for that table at attach (ezlogs.capture_source): one INSERT ... SELECT inside one
-- exception block, whatever the row count, so an import or a bulk update never opens a
-- subtransaction per row. Its select list leaves sensitive and ignored columns out and replaces
-- bytea, vector, tsvector and any value over 8 KB by its stored size, never reading it.

-- A captured row as it is stored: sensitive keys dropped inside json columns, oversized values
-- replaced by their size, and a row that still would not fit in a post replaced by a note.
CREATE OR REPLACE FUNCTION ezlogs.finish_row(j jsonb, jcols text[]) RETURNS jsonb
  LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  col text;
BEGIN
  IF j IS NULL THEN
    RETURN NULL;
  END IF;
  FOREACH col IN ARRAY COALESCE(jcols, '{}') LOOP
    IF j ? col THEN
      j := jsonb_set(j, ARRAY[col], COALESCE(ezlogs.strip_nested(j->col, 1), 'null'));
    END IF;
  END LOOP;
  IF pg_column_size(j) <= 8192 THEN
    RETURN j;   -- small: nothing to cut (the common case, measured without serialising)
  END IF;
  j := ezlogs.cap_size(j);
  IF octet_length(j::text) > 40960 THEN
    RETURN jsonb_build_object('note', 'row too large to record');
  END IF;
  RETURN j;
END;
$$;

-- An update's two images reduced to what changed, plus the columns it always keeps (its key and
-- name columns); nothing (NULLs) when nothing changed.
CREATE OR REPLACE FUNCTION ezlogs.diff_rows(old_j jsonb, new_j jsonb, keep text[], OUT old_out jsonb, OUT new_out jsonb)
  LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  keys text[];
BEGIN
  SELECT array_agg(e.key) INTO keys FROM jsonb_each(new_j) e WHERE (old_j -> e.key) IS DISTINCT FROM e.value;
  IF keys IS NULL THEN
    RETURN;
  END IF;
  SELECT jsonb_object_agg(k, old_j -> k) FILTER (WHERE old_j ? k),
         jsonb_object_agg(k, new_j -> k) FILTER (WHERE new_j ? k)
    INTO old_out, new_out
    FROM (SELECT DISTINCT unnest(keys || COALESCE(keep, '{}')) AS k) u;
END;
$$;

-- An update over this many rows is recorded with its row count only: summarising every column of
-- every row would add seconds to a very large statement (and to the app's statement timeout).
CREATE OR REPLACE FUNCTION ezlogs.bulk_summary_max() RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 10000 $$;

-- The equality operator of a type, schema-qualified (pgvector's and citext's live outside
-- pg_catalog, and capture runs with search_path = ezlogs); NULL when the type has none.
CREATE OR REPLACE FUNCTION ezlogs.eq_op(typ oid) RETURNS text
  LANGUAGE sql STABLE
AS $$
  -- The type's own, else the one of a type it converts to without change (varchar uses text's).
  SELECT format('OPERATOR(%I.=)', n.nspname)
    FROM pg_operator o JOIN pg_namespace n ON n.oid = o.oprnamespace
   WHERE o.oprname = '=' AND o.oprresult = 'boolean'::regtype
     AND ((o.oprleft = typ AND o.oprright = typ)
          OR (o.oprleft = o.oprright AND o.oprleft IN (SELECT casttarget FROM pg_cast
                                                        WHERE castsource = typ AND castmethod = 'b' AND castcontext = 'i')))
   ORDER BY o.oprleft = typ DESC, n.nspname = 'pg_catalog' DESC
   LIMIT 1
$$;

-- Whether a column differs between an update's old (o) and new (n) row, for the bulk summary: the
-- text form, which is exact for every type (a type's own "=" can call different values equal:
-- box by area, interval '1 day' and '24 hours', citext by case). Binary types use their own equality.
CREATE OR REPLACE FUNCTION ezlogs.changed_expr(col text, typ oid) RETURNS text
  LANGUAGE sql STABLE
AS $$
  SELECT CASE WHEN (SELECT typname FROM pg_type WHERE oid = typ) IN ('bytea', 'vector', 'halfvec', 'sparsevec')
                   AND ezlogs.eq_op(typ) IS NOT NULL
              THEN format('((n.%1$I IS NULL) <> (o.%1$I IS NULL) OR NOT (n.%1$I %2$s o.%1$I))', col, ezlogs.eq_op(typ))
              ELSE format('(n.%1$I::text IS DISTINCT FROM o.%1$I::text)', col) END
$$;

-- The body of one table's capture function for one operation (ezlogs.attach creates it as
-- ezlogs.cap_<table oid>_<ins|upd|del>_<suffix>). Static SQL, so Postgres plans it once per
-- connection, not once per statement. Every name and value is quoted here. Variables are always
-- written fn.<name> and columns win any other clash (#variable_conflict use_column), so a column
-- named like a variable (summary, claims, new, found) can't break it. pk_eq: the key type's
-- equality operator (ezlogs.eq_op).
CREATE OR REPLACE FUNCTION ezlogs.capture_source(op text, tbl text, pk text, pk_eq text, sel text, jcols text[], keep text[],
                                                 summary text)
  RETURNS text
  LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  tr      text := CASE op WHEN 'DELETE' THEN 'o' ELSE 'n' END;   -- the transition table read
  samples text := format('(SELECT jsonb_agg(x) FROM (SELECT t.%I::text AS x FROM %s t LIMIT 5) s)', pk, tr);
  bulk    text;
  rows_q  text;
BEGIN
  IF op = 'UPDATE' THEN
    -- A statement that changed keys: its old and new rows can't be paired, so it is recorded as a
    -- count (never as one row's values moved onto another).
    rows_q := format(
      'IF EXISTS (SELECT 1 FROM n nk WHERE NOT EXISTS (SELECT 1 FROM o ok WHERE ok.%1$I %5$s nk.%1$I)) THEN '
      '  INSERT INTO ezlogs.outbox (schema_name, table_name, op, row_count, bulk, claims, correlation_id) '
      '  VALUES (''public'', %2$L, ''UPDATE'', fn.cnt, jsonb_build_object(''columns'', jsonb_build_object(%1$L, ''{"changed": true}''::jsonb), ''sample_ids'', %3$s), fn.claims, fn.cid); '
      'ELSE '
      '  INSERT INTO ezlogs.outbox (schema_name, table_name, op, old_row, new_row, resource_id, claims, correlation_id) '
      '  SELECT ''public'', %2$L, ''UPDATE'', d.old_out, d.new_out, left(nw.%1$I::text, 200), fn.claims, fn.cid '
      '  FROM (SELECT %4$s FROM n) nw JOIN (SELECT %4$s FROM o) od ON od.%1$I %5$s nw.%1$I '
      '  CROSS JOIN LATERAL ezlogs.diff_rows(ezlogs.finish_row(to_jsonb(od.*), %6$L::text[]), ezlogs.finish_row(to_jsonb(nw.*), %6$L::text[]), %7$L::text[]) d '
      '  WHERE d.new_out IS NOT NULL; '
      'END IF;',
      pk, tbl, samples, sel, pk_eq, jcols, keep);
    bulk := format(
      'IF fn.cnt <= ezlogs.bulk_summary_max() AND NOT EXISTS (SELECT nk.%1$I FROM n nk EXCEPT ALL SELECT ok.%1$I FROM o ok) THEN '
      '  SELECT jsonb_build_object(''columns'', %2$s, ''sample_ids'', %3$s) INTO fn.summary FROM n JOIN o ON o.%1$I %4$s n.%1$I; '
      '  IF fn.summary IS NULL OR fn.summary->''columns'' = ''{}''::jsonb THEN RETURN NULL; END IF; '
      'ELSE '
      '  fn.summary := jsonb_build_object(''sample_ids'', %3$s); '
      'END IF; '
      'INSERT INTO ezlogs.outbox (schema_name, table_name, op, row_count, bulk, claims, correlation_id) '
      'VALUES (''public'', %5$L, ''UPDATE'', fn.cnt, fn.summary, fn.claims, fn.cid);',
      pk, COALESCE(NULLIF(summary, ''), '''{}''::jsonb'), samples, pk_eq, tbl);
  ELSE
    bulk := format(
      'INSERT INTO ezlogs.outbox (schema_name, table_name, op, row_count, bulk, claims, correlation_id) '
      'VALUES (''public'', %1$L, %2$L, fn.cnt, jsonb_build_object(''sample_ids'', %3$s), fn.claims, fn.cid);',
      tbl, op, samples);
    rows_q := format(
      'INSERT INTO ezlogs.outbox (schema_name, table_name, op, %1$s, resource_id, claims, correlation_id) '
      'SELECT ''public'', %2$L, %3$L, ezlogs.finish_row(to_jsonb(s.*), %4$L::text[]), left(s.%5$I::text, 200), fn.claims, fn.cid '
      'FROM (SELECT %6$s FROM %7$s) s;',
      CASE op WHEN 'DELETE' THEN 'old_row' ELSE 'new_row' END, tbl, op, jcols, pk, sel, tr);
  END IF;
  RETURN format($body$
#variable_conflict use_column
<<fn>>
DECLARE
  cnt     bigint;
  claims  jsonb;
  cid     text;
  summary jsonb;
BEGIN
  SELECT count(*) INTO fn.cnt FROM %1$s;
  IF fn.cnt = 0 OR NOT ezlogs.begin_capture() THEN
    RETURN NULL;
  END IF;
  fn.claims := ezlogs.request_claims();
  fn.cid := ezlogs.request_correlation_id();
  IF fn.cnt > ezlogs.bulk_threshold() THEN
    %2$s
  ELSE
    %3$s
  END IF;
  RETURN NULL;
EXCEPTION WHEN others THEN
  -- Never break the app's write. Losing one statement's changes is recoverable; a failed save is not.
  RAISE WARNING '[ezlogs] capture on %%.%% failed (write continues): %%', TG_TABLE_SCHEMA, TG_TABLE_NAME, SQLERRM;
  -- Most often the table changed and this function is out of date (a host without event triggers):
  -- at commit, the flush job is asked to re-attach tables (ezlogs.ship_at_commit).
  BEGIN
    PERFORM set_config('ezlogs.capture_failed', '1', true);
    PERFORM ezlogs.begin_capture();
  EXCEPTION WHEN others THEN
    NULL;
  END;
  RETURN NULL;
END;
$body$, tr, bulk, rows_q);
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
    'recovery_sent_at',   j->'recovery_sent_at',
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
  -- A password change is only a fact: that the hash differs. Nothing derived from it is kept.
  IF TG_OP = 'UPDATE' AND to_jsonb(OLD)->>'encrypted_password' IS DISTINCT FROM to_jsonb(NEW)->>'encrypted_password' THEN
    new_json := new_json || '{"pw_changed": true}'::jsonb;
  END IF;
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
-- What a table's capture triggers were built from: its columns and their types, its key, the
-- columns left out or naming its rows, and the rules version. Stored as the triggers' last
-- argument, so a schema change (even on a host without event triggers) re-attaches the table.
CREATE OR REPLACE FUNCTION ezlogs.table_signature(target regclass) RETURNS text
  LANGUAGE sql STABLE
  SET search_path = ezlogs, pg_temp
AS $$
  SELECT md5(concat_ws('|', ezlogs.version(), ezlogs.patterns_version(),
    (SELECT relname FROM pg_class WHERE oid = target),   -- a renamed table is recorded under its new name
    (SELECT string_agg(a.attnum || ':' || a.attname || ':' || a.atttypid, ',' ORDER BY a.attnum)
       FROM pg_attribute a WHERE a.attrelid = target AND a.attnum > 0 AND NOT a.attisdropped),
    (SELECT string_agg(i.indkey::text, ',') FROM pg_index i WHERE i.indrelid = target AND i.indisprimary),
    (SELECT string_agg(c.condeferrable::text, ',') FROM pg_constraint c WHERE c.conrelid = target AND c.contype = 'p'),
    (SELECT columns::text FROM ezlogs.ignored_columns WHERE table_oid = target),
    (SELECT column_name FROM ezlogs.record_names WHERE table_oid = target)))
$$;

-- A column's name as EZLogs' server compares it (lowercase, no underscores), and the table's
-- `<record>number` column in that form: the same rules as EventIngest::PostgresRows#singular_norm.
CREATE OR REPLACE FUNCTION ezlogs.name_norm(name text) RETURNS text
  LANGUAGE sql IMMUTABLE
AS $$ SELECT lower(replace(name, '_', '')) $$;

CREATE OR REPLACE FUNCTION ezlogs.numbered_norm(table_name text) RETURNS text
  LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE WHEN t ~ 'ies$' THEN left(t, -3) || 'y'
              WHEN t ~ '(ss|us|is)$' THEN t
              WHEN t ~ '(xes|ches|shes|sses)$' THEN left(t, -2)
              WHEN t ~ 's$' THEN left(t, -1)
              ELSE t END || 'number'
    FROM (SELECT ezlogs.name_norm(table_name) AS t) n
$$;

CREATE OR REPLACE FUNCTION ezlogs.attach(target regclass, by_person boolean DEFAULT false) RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
  SET lock_timeout = '100ms'
AS $$
DECLARE
  rel      pg_class%ROWTYPE;
  pk       text;
  pk_type  oid;
  pk_eq    text;
  jcols    text[];
  ignored  text[];
  sig      text;
  op       text;
  fname    text;
  sel      text;
  sel_upd  text;
  keep     text[];
  summary  text;
  suffix   text;
BEGIN
  SELECT * INTO rel FROM pg_class WHERE oid = target;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  -- A partition is captured by its parent's row trigger (cloned onto it): a table attached as a
  -- partition after it was tracked on its own loses its own triggers, so nothing is recorded twice.
  IF rel.relispartition THEN
    IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = target AND tgname LIKE 'ezlogs\_capture%' AND tgparentid = 0) THEN
      PERFORM ezlogs.detach(target);
    END IF;
    RETURN false;
  END IF;
  -- A table whose name is skipped is recorded only when a person tracked it (ezlogs.track).
  IF rel.relnamespace <> 'public'::regnamespace OR rel.relkind NOT IN ('r', 'p')
     OR (NOT by_person AND ezlogs.skipped(rel.relname) AND NOT EXISTS (SELECT 1 FROM ezlogs.tracked k WHERE k.table_oid = target))
     OR EXISTS (SELECT 1 FROM ezlogs.excluded e WHERE e.table_oid = target) THEN
    IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = target AND tgname LIKE 'ezlogs\_capture%' AND tgparentid = 0)
       AND rel.relnamespace = 'public'::regnamespace THEN
      PERFORM ezlogs.detach(target);   -- renamed to a name EZLogs skips (a secrets table): stop recording it
    END IF;
    RETURN false;
  END IF;

  SELECT a.attname, CASE WHEN t.typtype = 'd' THEN t.typbasetype ELSE t.oid END INTO pk, pk_type
    FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
    JOIN pg_type t ON t.oid = a.atttypid
   WHERE i.indrelid = target AND i.indisprimary AND array_length(i.indkey, 1) = 1
   LIMIT 1;
  pk_eq := ezlogs.eq_op(pk_type);
  SELECT columns INTO ignored FROM ezlogs.ignored_columns WHERE table_oid = target;
  ignored := COALESCE(ignored, '{}');

  -- One trigger per row, as before 1.5.0, for a table without a one-column key (an update's old
  -- and new rows can't be paired) and for a partitioned table (a statement trigger on the parent
  -- misses writes made to a partition directly; a row trigger is cloned onto every partition).
  -- A deferrable key can be swapped within one statement (id = 3 - id), which would pair rows wrongly.
  IF pk IS NULL OR pk_eq IS NULL OR ezlogs.is_sensitive_key(pk) OR rel.relkind = 'p'
     OR EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = target AND contype = 'p' AND condeferrable) THEN
    RETURN ezlogs.attach_rows(target, rel, pk);
  END IF;

  -- The select list: each column EZLogs may record, large values replaced by their stored size.
  SELECT string_agg(
           CASE
             WHEN a.attname = pk THEN format('%I', a.attname)   -- the key as it is: it names the row
             WHEN bt.typname IN ('bytea', 'vector', 'halfvec', 'sparsevec', 'tsvector', 'tsquery') THEN
               format('CASE WHEN %1$I IS NULL THEN NULL ELSE ezlogs.size_note(pg_column_size(%1$I)) END AS %1$I', a.attname)
             WHEN t.typlen = -1 THEN
               format('CASE WHEN pg_column_size(%1$I) > 8192 THEN ezlogs.size_note(pg_column_size(%1$I)) ELSE to_jsonb(%1$I) END AS %1$I', a.attname)
             ELSE format('%I', a.attname)
           END, ', ' ORDER BY a.attnum),
         COALESCE(array_agg(a.attname::text ORDER BY a.attnum) FILTER (
           WHERE bt.typname IN ('json', 'jsonb', 'hstore') OR bt.typtype = 'c' OR bt.typcategory = 'A'), '{}'),
         -- An update's rows (at most bulk_threshold() of them): a large value measured by its text
         -- length on both sides, so a value the statement only sent again never reads as changed
         -- (stored sizes differ between a compressed old value and a new one).
         string_agg(
           CASE
             WHEN a.attname = pk THEN format('%I', a.attname)
             WHEN bt.typname = 'bytea' THEN
               format('CASE WHEN %1$I IS NULL THEN NULL ELSE ezlogs.size_note(octet_length(%1$I)) END AS %1$I', a.attname)
             WHEN bt.typname IN ('vector', 'halfvec', 'sparsevec', 'tsvector', 'tsquery') THEN
               format('CASE WHEN %1$I IS NULL THEN NULL ELSE ezlogs.size_note(octet_length(%1$I::text)) END AS %1$I', a.attname)
             WHEN t.typlen = -1 THEN
               format('CASE WHEN octet_length(%1$I::text) > 8192 THEN ezlogs.size_note(octet_length(%1$I::text)) ELSE to_jsonb(%1$I) END AS %1$I', a.attname)
             ELSE format('%I', a.attname)
           END, ', ' ORDER BY a.attnum),
         -- An update's summary when it changed more than bulk_threshold() rows: each changed column,
         -- with its new value (as text, at most 200 bytes) when every row got the same one, else
         -- {"changed": true}. Nested types (json: secrets inside) and large ones never carry a value.
         -- Compared by their text form (exact). A value stored over 8 KB is read only when its stored
         -- size differs from the other side's (an untouched value keeps its stored form and size; a
         -- re-sent one differs in form): a same-size change to a large value is not seen here.
         string_agg(
           CASE WHEN a.attname = pk THEN NULL   -- rows are paired by it: it never changes here
           ELSE format('CASE WHEN bool_or(%2$s) THEN jsonb_build_object(%1$L, %3$s) ELSE ''{}''::jsonb END',
                  a.attname,
                  CASE WHEN t.typlen = -1
                       THEN format('CASE WHEN pg_column_size(n.%1$I) > 8192 OR pg_column_size(o.%1$I) > 8192 '
                                   'THEN CASE WHEN pg_column_size(n.%1$I) IS NOT DISTINCT FROM pg_column_size(o.%1$I) THEN false '
                                   'ELSE %2$s END ELSE %2$s END',
                                   a.attname, ezlogs.changed_expr(a.attname, bt.oid))
                       ELSE ezlogs.changed_expr(a.attname, bt.oid) END,
                  CASE WHEN bt.typname IN ('bytea', 'vector', 'halfvec', 'sparsevec', 'tsvector', 'tsquery', 'json', 'jsonb', 'hstore')
                         OR bt.typtype = 'c' OR bt.typcategory = 'A'
                       THEN '''{"changed": true}''::jsonb'
                       ELSE format('CASE WHEN count(n.%1$I) = 0 THEN ''null''::jsonb '
                                   'WHEN count(n.%1$I) FILTER (WHERE pg_column_size(n.%1$I) <= 256) = count(*) '
                                   'AND min(n.%1$I::text) FILTER (WHERE pg_column_size(n.%1$I) <= 256) '
                                   '  = max(n.%1$I::text) FILTER (WHERE pg_column_size(n.%1$I) <= 256) '
                                   'AND octet_length(min(n.%1$I::text) FILTER (WHERE pg_column_size(n.%1$I) <= 256)) <= 200 '
                                   'THEN to_jsonb(min(n.%1$I::text) FILTER (WHERE pg_column_size(n.%1$I) <= 256)) '
                                   'ELSE ''{"changed": true}''::jsonb END', a.attname) END)
           END, ' || ' ORDER BY a.attnum)
    INTO sel, jcols, sel_upd, summary
    FROM pg_attribute a
    JOIN pg_type t ON t.oid = a.atttypid
    JOIN pg_type bt ON bt.oid = CASE WHEN t.typtype = 'd' THEN t.typbasetype ELSE t.oid END
   WHERE a.attrelid = target AND a.attnum > 0 AND NOT a.attisdropped
     AND NOT ezlogs.is_sensitive_key(a.attname) AND (a.attname = pk OR NOT a.attname = ANY(ignored));

  -- What an update always carries besides its changes: the key, and the columns that name a row,
  -- matched as the server matches them (name, title, number, label, <record>_number, any case or
  -- underscores) and the one set with ezlogs.name_records.
  SELECT array_agg(a.attname::text) INTO keep
    FROM pg_attribute a
   WHERE a.attrelid = target AND a.attnum > 0 AND NOT a.attisdropped AND NOT ezlogs.is_sensitive_key(a.attname)
     AND NOT a.attname = ANY(ignored)
     AND (a.attname = pk OR ezlogs.name_norm(a.attname) IN ('name', 'title', 'number', 'label', ezlogs.numbered_norm(rel.relname))
          OR a.attname = (SELECT column_name FROM ezlogs.record_names WHERE table_oid = target));
  keep := array_append(array_remove(keep, pk), pk);

  sig := ezlogs.table_signature(target);
  -- Already attached by this version for these columns: leave it (no lock, no catalog churn).
  IF (SELECT count(*) FROM pg_trigger t JOIN pg_proc f ON f.oid = t.tgfoid
       WHERE t.tgrelid = target AND t.tgparentid = 0
         AND t.tgname IN ('ezlogs_capture_ins', 'ezlogs_capture_upd', 'ezlogs_capture_del')
         AND f.pronamespace = 'ezlogs'::regnamespace AND f.proname ~ '^cap_[0-9]+_(ins|upd|del)_[0-9a-f]{8}$'
         AND t.tgargs = convert_to(sig, 'UTF8') || '\x00'::bytea) = 3
     AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'ezlogs_capture' AND tgrelid = target) THEN
    RETURN true;
  END IF;

  PERFORM ezlogs.detach(target);
  -- Function names carry a fresh suffix, so they never collide with functions a restore brought
  -- back under another table's old oid.
  suffix := left(md5(sig || clock_timestamp()::text || random()::text), 8);
  FOREACH op IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE'] LOOP
    fname := format('cap_%s_%s_%s', target::oid, lower(left(op, 3)), suffix);
    EXECUTE format('CREATE FUNCTION ezlogs.%I() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER '
                   'SET search_path = ezlogs, pg_temp AS %L', fname,
                   ezlogs.capture_source(op, rel.relname, pk, pk_eq,
                                         CASE op WHEN 'UPDATE' THEN COALESCE(sel_upd, format('%I', pk)) ELSE COALESCE(sel, format('%I', pk)) END,
                                         jcols, keep, summary));
    EXECUTE format('REVOKE ALL ON FUNCTION ezlogs.%I() FROM PUBLIC', fname);
    EXECUTE format('CREATE TRIGGER %I AFTER %s ON %s REFERENCING %s FOR EACH STATEMENT EXECUTE FUNCTION ezlogs.%I(%L)',
                   'ezlogs_capture_' || lower(left(op, 3)), op, target,
                   CASE op WHEN 'INSERT' THEN 'NEW TABLE AS n' WHEN 'DELETE' THEN 'OLD TABLE AS o'
                           ELSE 'OLD TABLE AS o NEW TABLE AS n' END,
                   fname, sig);
  END LOOP;
  RETURN true;
END;
$$;

-- Every EZLogs capture trigger of a table, whichever kind (row or statement; a partition's clones
-- go with its parent's), and the capture functions those triggers used.
CREATE OR REPLACE FUNCTION ezlogs.detach(target regclass) RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  tg    record;
  funcs oid[];
BEGIN
  SELECT array_agg(DISTINCT tgfoid) INTO funcs
    FROM pg_trigger WHERE tgrelid = target AND tgname LIKE 'ezlogs\_capture%' AND NOT tgisinternal AND tgparentid = 0;
  FOR tg IN SELECT tgname FROM pg_trigger
             WHERE tgrelid = target AND tgname LIKE 'ezlogs\_capture%' AND NOT tgisinternal AND tgparentid = 0 LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', tg.tgname, target);
  END LOOP;
  FOR tg IN SELECT p.oid::regprocedure AS f FROM pg_proc p
             WHERE p.oid = ANY(COALESCE(funcs, '{}')) AND p.pronamespace = 'ezlogs'::regnamespace AND p.proname ~ '^cap_'
               AND NOT EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgfoid = p.oid) LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %s', tg.f);
  END LOOP;
END;
$$;

-- A table without a one-column key: one row trigger (ezlogs.capture_row), the 1.4.0 way.
CREATE OR REPLACE FUNCTION ezlogs.attach_rows(target regclass, rel pg_class, pk text) RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  secret text[];
  cols   text[];
  jcols  text[];
  argv   text[];
  trig_name text;
  part      regclass;
BEGIN
  -- Dropped from every row: secret-named columns and the ones a person left out (ignore_columns).
  SELECT COALESCE(array_agg(a.attname::text) FILTER (
           WHERE ezlogs.is_sensitive_key(a.attname)
              OR a.attname = ANY(COALESCE((SELECT columns FROM ezlogs.ignored_columns WHERE table_oid = target), '{}'))), '{}'),
         ARRAY(SELECT jsonb_object_keys(jsonb_object_agg(a.attname, NULL::int))),
         COALESCE(array_agg(a.attname::text) FILTER (
           WHERE NOT ezlogs.is_sensitive_key(a.attname)
             AND (bt.typname IN ('json', 'jsonb', 'hstore') OR bt.typtype = 'c' OR bt.typcategory = 'A')), '{}')
    INTO secret, cols, jcols
    FROM pg_attribute a
    JOIN pg_type t ON t.oid = a.atttypid
    JOIN pg_type bt ON bt.oid = CASE WHEN t.typtype = 'd' THEN t.typbasetype ELSE t.oid END
   WHERE a.attrelid = target AND a.attnum > 0 AND NOT a.attisdropped;

  argv := ARRAY[COALESCE(pk, ''), secret::text, cols::text, ezlogs.patterns_version(), rel.relname, jcols::text,
                ezlogs.table_signature(target)];
  -- A partitioned table's trigger is cloned onto every partition: its own name, so attaching a table
  -- that has its own capture as a partition never fails on a name clash.
  trig_name := CASE WHEN rel.relkind = 'p' THEN 'ezlogs_capture_part' ELSE 'ezlogs_capture' END;
  IF rel.relkind = 'p' THEN
    FOR part IN SELECT inhrelid::regclass FROM pg_inherits WHERE inhparent = target LOOP
      IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = part AND tgname LIKE 'ezlogs\_capture%' AND tgparentid = 0) THEN
        PERFORM ezlogs.detach(part);
      END IF;
    END LOOP;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger t
              WHERE t.tgname = trig_name AND t.tgrelid = target
                AND t.tgfoid = 'ezlogs.capture_row'::regproc
                AND t.tgargs = (SELECT string_agg(convert_to(a, 'UTF8') || '\x00'::bytea, ''::bytea ORDER BY n)
                                  FROM unnest(argv) WITH ORDINALITY AS u(a, n)))
     AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname LIKE 'ezlogs\_capture%' AND tgname <> trig_name
                      AND tgrelid = target AND tgparentid = 0) THEN
    RETURN true;
  END IF;
  PERFORM ezlogs.detach(target);
  EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %s '
                 'FOR EACH ROW EXECUTE FUNCTION ezlogs.capture_row(%s)', trig_name, target,
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
  INSERT INTO ezlogs.tracked (table_oid) VALUES (target) ON CONFLICT DO NOTHING;
  RETURN ezlogs.attach(target, by_person => true);
END;
$$;

-- For people: name a table's rows by one of its columns, for a table with no name, title, number
-- or label column (those already name rows): select ezlogs.name_records('public.<table>', '<column>');
-- (for example ('public.invoices', 'reference')). A NULL column goes back to the default. Refuses a
-- table or column that doesn't exist, and a column named like a secret (never sent, so it can't
-- name anything). Safe in a migration, one IF block per table:
--   DO $$ BEGIN IF to_regprocedure('ezlogs.name_records(text,text)') IS NOT NULL
--     AND to_regclass('public.<table>') IS NOT NULL THEN
--     PERFORM ezlogs.name_records('public.<table>', '<column>'); END IF; END $$;
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
    PERFORM ezlogs.attach(t);
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
  PERFORM ezlogs.attach(t); -- an update always carries the name column
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

-- For people: leave a table's noisy columns out (a heartbeat such as last_seen_at), never sent;
-- an update that changed only these is not recorded. select ezlogs.ignore_columns('public.profiles',
-- ARRAY['last_seen_at']); an empty array or NULL forgets the setting. Safe in a migration, guarded
-- like name_records. Refuses a table EZLogs doesn't record or a column it doesn't have.
CREATE OR REPLACE FUNCTION ezlogs.ignore_columns(target text, column_names text[]) RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  t       regclass := to_regclass(target);
  rel     pg_class%ROWTYPE;
  missing text;
BEGIN
  IF t IS NULL THEN
    RAISE EXCEPTION 'ezlogs.ignore_columns: there is no table %', target
      USING HINT = 'Write it as schema.table, for example ''public.profiles''.';
  END IF;
  SELECT * INTO rel FROM pg_class WHERE oid = t;
  IF rel.relnamespace <> 'public'::regnamespace OR rel.relkind NOT IN ('r', 'p') OR rel.relispartition THEN
    RAISE EXCEPTION 'ezlogs.ignore_columns: % is not one of the app''s tables EZLogs records (a table in public)', t;
  END IF;
  IF array_position(column_names, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'ezlogs.ignore_columns: a column name is missing (NULL) in the list';
  END IF;
  IF COALESCE(cardinality(column_names), 0) = 0 THEN
    DELETE FROM ezlogs.ignored_columns WHERE table_oid = t;
    PERFORM ezlogs.attach(t);
    RETURN format('%s: no columns left out', t);
  END IF;
  SELECT c INTO missing FROM unnest(column_names) c
   WHERE NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = t AND attname = c AND attnum > 0 AND NOT attisdropped)
   LIMIT 1;
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'ezlogs.ignore_columns: % has no column %', t, missing;
  END IF;
  SELECT a.attname INTO missing
    FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
   WHERE i.indrelid = t AND i.indisprimary AND a.attname = ANY(column_names)
   LIMIT 1;
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'ezlogs.ignore_columns: % is part of the primary key of %, which names each row, so it can''t be left out', missing, t;
  END IF;
  INSERT INTO ezlogs.ignored_columns (table_oid, columns) VALUES (t, column_names)
    ON CONFLICT (table_oid) DO UPDATE SET columns = EXCLUDED.columns;
  PERFORM ezlogs.attach(t);
  RETURN format('%s: leaving out %s', t, array_to_string(column_names, ', '));
END;
$$;

-- For people: stop recording a table, for good (until ezlogs.track). Survives renames.
CREATE OR REPLACE FUNCTION ezlogs.untrack(target regclass) RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
BEGIN
  INSERT INTO ezlogs.excluded (table_oid) VALUES (target) ON CONFLICT DO NOTHING;
  DELETE FROM ezlogs.tracked WHERE table_oid = target;
  PERFORM ezlogs.detach(target);
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

-- Capture functions (cap_<oid>_*) whose table is gone: at most 100 per call.
CREATE OR REPLACE FUNCTION ezlogs.drop_orphan_captures() RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  f regprocedure;
BEGIN
  -- Only functions no trigger uses (whatever table or oid their name mentions: a restore can
  -- change oids), each on its own: one that can't be dropped never stops the others or the job.
  FOR f IN SELECT p.oid::regprocedure FROM pg_proc p
            WHERE p.pronamespace = 'ezlogs'::regnamespace AND p.proname ~ '^cap_[0-9]+_(ins|upd|del)'
              AND NOT EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgfoid = p.oid)
            LIMIT 100 LOOP
    BEGIN
      EXECUTE format('DROP FUNCTION IF EXISTS %s', f);
    EXCEPTION WHEN others THEN
      RAISE WARNING '[ezlogs] could not remove % (retried later): %', f, SQLERRM;
    END;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION ezlogs.reconcile() RETURNS int
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  t       regclass;
  n       int := 0;
  pending boolean := false;
  prev_timeout text := current_setting('lock_timeout');
BEGIN
  IF NOT ezlogs.connected() THEN
    RETURN 0;
  END IF;
  PERFORM ezlogs.attach_platform();
  -- At most 10 tables (re)attached per run, each holding its lock only until this run commits,
  -- so an install or an upgrade on a large schema never blocks the app's writes for long; the
  -- rest wait for the next run (5 seconds later).
  FOR t IN SELECT c.oid::regclass FROM pg_class c
            WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p') AND NOT c.relispartition
            ORDER BY c.oid
  LOOP
    IF n >= 10 THEN
      pending := true;
      EXIT;
    END IF;
    BEGIN
      IF ezlogs.attach_needed(t) AND ezlogs.attach(t) THEN n := n + 1; END IF;
    EXCEPTION WHEN others THEN
      RAISE WARNING '[ezlogs] could not track % now (retried later): %', t, SQLERRM;
    END;
  END LOOP;
  -- A table attached as a partition after it was tracked on its own: its parent's trigger covers it.
  -- Dropping a trigger locks the table: wait at most 100 ms, else next run.
  PERFORM set_config('lock_timeout', '100ms', true);
  FOR t IN SELECT DISTINCT tg.tgrelid::regclass FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid
            WHERE c.relispartition AND tg.tgname LIKE 'ezlogs\_capture%' AND tg.tgparentid = 0 LIMIT 10 LOOP
    BEGIN
      PERFORM ezlogs.detach(t);
    EXCEPTION WHEN others THEN
      RAISE WARNING '[ezlogs] could not update % now (retried later): %', t, SQLERRM;
    END;
  END LOOP;
  PERFORM set_config('lock_timeout', prev_timeout, true);
  -- Capture functions left by dropped tables (their triggers went with the table).
  PERFORM ezlogs.drop_orphan_captures();
  -- The outbox's cap: 5% of the database, between 10 MB (so a small app rides out a short outage)
  -- and 50 MB.
  UPDATE ezlogs.state
     SET last_reconciled = CASE WHEN pending THEN NULL ELSE now() END,
         outbox_cap_bytes = greatest(10485760, least(52428800, pg_database_size(current_database()) / 20))
   WHERE one;
  RETURN n;
END;
$$;

-- Whether a table's triggers are missing or out of date (a cheap catalog check, before attach
-- builds anything): no EZLogs trigger yet, or ones made by an older version.
CREATE OR REPLACE FUNCTION ezlogs.attach_needed(target regclass) RETURNS boolean
  LANGUAGE sql STABLE
  SET search_path = ezlogs, pg_temp
AS $$
  SELECT NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = target AND tgname LIKE 'ezlogs\_capture%')
      OR EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = target AND tgname LIKE 'ezlogs\_capture%'
                  AND position(convert_to(ezlogs.table_signature(target), 'UTF8') in tgargs) = 0)
$$;

-- Attach (or refresh) every table: through the flush job when pg_cron is there (10 tables per run,
-- never a long lock), else here and now.
CREATE OR REPLACE FUNCTION ezlogs.queue_reconcile() RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ezlogs, pg_temp
AS $$
DECLARE
  i int;
BEGIN
  IF NOT ezlogs.connected() THEN
    RETURN;
  END IF;
  UPDATE ezlogs.state SET last_reconciled = NULL WHERE one;
  IF to_regclass('cron.job') IS NOT NULL THEN
    PERFORM ezlogs.ensure_flush_job();
  ELSE
    FOR i IN 1..1000 LOOP
      PERFORM ezlogs.reconcile();
      EXIT WHEN (SELECT last_reconciled IS NOT NULL FROM ezlogs.state WHERE one);
    END LOOP;
  END IF;
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
    || CASE WHEN o.row_count IS NOT NULL THEN jsonb_build_object('row_count', o.row_count, 'bulk', o.bulk) ELSE '{}'::jsonb END
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
           -- About how many wait (ids run in order; read from the unsent index, never counted).
           'waiting_rows', (SELECT COALESCE(max(id) - min(id) + 1, 0) FROM ezlogs.outbox WHERE request_id IS NULL),
           'capture_paused', CASE WHEN st.capture_paused_at IS NOT NULL
                                  THEN jsonb_build_object('since', st.capture_paused_at, 'reason', st.capture_paused_reason) END,
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
  IF to_regclass('cron.job') IS NULL OR EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ezlogs-flush') THEN
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
  DELETE FROM ezlogs.tx_marks WHERE txid = txid_current();
  -- A SERIALIZABLE transaction would take on our reads as conflicts: leave its rows to the
  -- next writer or the flush job.
  IF current_setting('transaction_isolation') = 'serializable' THEN
    RETURN NULL;
  END IF;
  SELECT * INTO st FROM ezlogs.state WHERE one FOR UPDATE SKIP LOCKED;
  IF NOT FOUND OR st.connected_at IS NULL THEN
    RETURN NULL;
  END IF;
  -- A capture failed in this transaction: re-attach tables on the next flush run.
  IF current_setting('ezlogs.capture_failed', true) = '1' AND st.last_reconciled IS NOT NULL THEN
    UPDATE ezlogs.state SET last_reconciled = NULL WHERE one;
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
DECLARE
  prev text := current_setting('lock_timeout');
BEGIN
  -- 1.5.0 ships once per transaction from ezlogs.tx_marks (one deferred event per transaction,
  -- not one per captured row). The 1.4.0 trigger on the outbox is removed if the outbox can be
  -- locked for a moment; if not, it stays harmlessly (shipping already runs once per transaction).
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'ezlogs_ship_at_commit' AND tgrelid = 'ezlogs.tx_marks'::regclass) THEN
    CREATE CONSTRAINT TRIGGER ezlogs_ship_at_commit AFTER INSERT ON ezlogs.tx_marks
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ezlogs.ship_at_commit();
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'ezlogs_ship_at_commit' AND tgrelid = 'ezlogs.outbox'::regclass) THEN
    BEGIN
      PERFORM set_config('lock_timeout', '500ms', true);
      DROP TRIGGER ezlogs_ship_at_commit ON ezlogs.outbox;
    EXCEPTION WHEN lock_not_available THEN
      RAISE NOTICE '[ezlogs] the outbox was busy: its 1.4.0 trigger stays until the next upgrade';
    END;
    PERFORM set_config('lock_timeout', prev, true);
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
  waiting_bytes numeric;
  probe_status  int;
  probe_key     text;
  posts         int;
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
      UPDATE ezlogs.state SET last_status = resp.status_code, last_error = NULL, failures = 0, paused_until = NULL,
                              blocked_since = NULL
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
             blocked_since = CASE WHEN resp.status_code IN (401, 402, 403, 423) THEN COALESCE(blocked_since, clock_timestamp())
                                  ELSE blocked_since END,
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

  -- 3b. Never fill the database (1.5.0). The waiting rows' size, estimated from the newest 100
  --     rows (index reads, constant time), against the cap measured at reconcile. Past it, or after
  --     an hour of refusals only a person can fix, capture pauses (rows are skipped, not queued);
  --     it resumes once the outbox is under half the cap, or once EZLogs accepts again.
  SELECT * INTO st FROM ezlogs.state WHERE one;
  SELECT COALESCE((SELECT max(id) - min(id) + 1 FROM ezlogs.outbox), 0)
         * COALESCE((SELECT avg(pg_column_size(o.*)) FROM (SELECT * FROM ezlogs.outbox ORDER BY id DESC LIMIT 100) o), 0)
    INTO waiting_bytes;
  IF st.capture_paused_at IS NULL THEN
    IF waiting_bytes > COALESCE(st.outbox_cap_bytes, 52428800) THEN
      UPDATE ezlogs.state SET capture_paused_at = clock_timestamp(),
                              capture_paused_reason = 'the outbox reached its size limit (EZLogs could not keep up)'
       WHERE one;
    ELSIF st.blocked_since < clock_timestamp() - interval '1 hour' THEN
      UPDATE ezlogs.state SET capture_paused_at = clock_timestamp(),
                              capture_paused_reason = 'EZLogs refused for an hour: ' || COALESCE(st.last_error, 'HTTP ' || st.last_status),
                              hello_request_id = NULL -- an older hello's answer must not end this pause
       WHERE one;
    END IF;
  ELSIF st.capture_paused_reason LIKE 'the outbox%' AND waiting_bytes < COALESCE(st.outbox_cap_bytes, 52428800) / 2 THEN
    UPDATE ezlogs.state SET capture_paused_at = NULL, capture_paused_reason = NULL WHERE one;
  ELSIF st.capture_paused_reason LIKE 'EZLogs refused%' AND st.blocked_since IS NULL THEN
    UPDATE ezlogs.state SET capture_paused_at = NULL, capture_paused_reason = NULL WHERE one;
  ELSIF st.capture_paused_reason LIKE 'EZLogs refused%' THEN
    -- Paused by refusals: ask again with an empty post (as connect does), at most once an hour;
    -- an accepting answer resumes capture.
    IF st.hello_request_id IS NOT NULL THEN
      EXECUTE 'SELECT status_code FROM net._http_response WHERE id = $1' INTO probe_status USING st.hello_request_id;
    END IF;
    IF probe_status BETWEEN 200 AND 299 THEN
      UPDATE ezlogs.state SET blocked_since = NULL, capture_paused_at = NULL, capture_paused_reason = NULL,
                              paused_until = NULL, failures = 0, last_status = probe_status, last_error = NULL, hello_request_id = NULL
       WHERE one;
    ELSIF st.paused_until IS NULL OR st.paused_until <= clock_timestamp() THEN
      SELECT decrypted_secret INTO probe_key FROM vault.decrypted_secrets WHERE name = 'ezlogs_ingest_key' LIMIT 1;
      IF probe_key IS NOT NULL THEN
        UPDATE ezlogs.state s
           SET paused_until = clock_timestamp() + interval '1 hour',
               hello_request_id = net.http_post(
                 url                  := ezlogs.endpoint(),
                 body                 := jsonb_build_object('install_id', s.install_id, 'version', ezlogs.version(),
                                                            'supabase_url', s.supabase_url, 'dropped_rows', s.dropped_total,
                                                            'capture_paused', jsonb_build_object('since', s.capture_paused_at, 'reason', s.capture_paused_reason),
                                                            'rows', '[]'::jsonb),
                 headers              := jsonb_build_object('Authorization', 'Bearer ' || probe_key, 'Content-Type', 'application/json'),
                 timeout_milliseconds := 10000)
         WHERE one;
      END IF;
    END IF;
  END IF;
  DELETE FROM ezlogs.tx_marks WHERE marked_at < clock_timestamp() - interval '1 minute';

  -- 4. Send what waits: more posts in flight the longer the backlog (10 to 25 posts of at most
  --    48 KB every 5 seconds, about 45,000 rows a minute), so an outage's backlog drains in
  --    minutes, and stays under EZLogs' limit of 600 posts a minute per key. Its own block: a
  --    failure here never undoes the confirmations and bounds above.
  BEGIN
    SELECT CASE WHEN w > 20000 THEN 25 WHEN w > 2000 THEN 15 ELSE 10 END INTO posts
      FROM (SELECT COALESCE(max(id) - min(id) + 1, 0) AS w FROM ezlogs.outbox WHERE request_id IS NULL) b;
    FOR i IN 1..posts LOOP
      EXIT WHEN ezlogs.send_batch() = 0;
    END LOOP;
  EXCEPTION WHEN others THEN
    RAISE WARNING '[ezlogs] sending failed (retried next run): %', SQLERRM;
  END;

  -- 5. Every 10 minutes (and while tables wait to be attached): new or changed tables, and the
  --    job's own run history (it would grow by 17,000 rows a day while the job runs). Last, so
  --    the table locks attaching takes are held only until this run commits, a moment later; its
  --    own block, so a failure never undoes the steps above.
  IF st.last_reconciled IS NULL OR st.last_reconciled < clock_timestamp() - interval '10 minutes' THEN
    BEGIN
      PERFORM ezlogs.reconcile();
    EXCEPTION WHEN others THEN
      RAISE WARNING '[ezlogs] attaching tables failed (retried next run): %', SQLERRM;
    END;
    BEGIN
      DELETE FROM cron.job_run_details
       WHERE jobid IN (SELECT jobid FROM cron.job WHERE jobname = 'ezlogs-flush')
         AND end_time < now() - interval '1 hour';
    EXCEPTION WHEN others THEN
      NULL;
    END;
  END IF;

  -- 6. Remove the job when nothing waits, when not connected, or when paused for a person.
  --    (A write that commits right after this check waits for the next write to ship.)
  SELECT * INTO st FROM ezlogs.state WHERE one;
  -- Never before every table is attached. While EZLogs refuses, an idle project keeps no job: the
  -- app's next write brings it back (captures mark their transaction even while paused), and
  -- that run checks the cap and asks EZLogs again once the hour is over.
  IF st.last_reconciled IS NOT NULL
     AND (st.connected_at IS NULL OR NOT EXISTS (SELECT 1 FROM ezlogs.outbox)
          OR (st.blocked_since IS NOT NULL AND st.paused_until > clock_timestamp())) THEN
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
     SET supabase_url = COALESCE(url, supabase_url), connected_at = now(), paused_until = NULL, failures = 0, last_error = NULL,
         blocked_since = NULL,
         capture_paused_at     = CASE WHEN capture_paused_reason LIKE 'EZLogs refused%' THEN NULL ELSE capture_paused_at END,
         capture_paused_reason = CASE WHEN capture_paused_reason LIKE 'EZLogs refused%' THEN NULL ELSE capture_paused_reason END
   WHERE one;

  PERFORM ezlogs.attach_platform();
  PERFORM ezlogs.queue_reconcile();

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
                (SELECT count(*) FROM pg_class c
                  WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p') AND NOT c.relispartition
                    AND NOT ezlogs.skipped(c.relname)
                    AND NOT EXISTS (SELECT 1 FROM ezlogs.excluded e WHERE e.table_oid = c.oid)));
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
    'waiting_rows',   (SELECT COALESCE(max(id) - min(id) + 1, 0) FROM ezlogs.outbox),
    'tracked_tables', (SELECT count(DISTINCT tgrelid) FROM pg_trigger WHERE tgname LIKE 'ezlogs\_capture%' AND NOT tgisinternal AND tgparentid = 0),
    'last_sent_at',   s.last_sent_at,
    'last_status',    s.last_status,
    'last_error',     s.last_error,
    'paused_until',   s.paused_until,
    'capture_paused', CASE WHEN s.capture_paused_at IS NOT NULL
                           THEN jsonb_build_object('since', s.capture_paused_at, 'reason', s.capture_paused_reason) END,
    'outbox_cap_bytes', s.outbox_cap_bytes,
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
  FOR r IN SELECT DISTINCT tgrelid::regclass AS rel FROM pg_trigger
            WHERE tgname LIKE 'ezlogs\_capture%' AND NOT tgisinternal AND tgparentid = 0 LOOP   -- clones go with their parent
    PERFORM ezlogs.detach(r.rel);
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

-- Already connected (re-applying the migration to upgrade): Supabase's own tables a newer version
-- reads are added now; the flush job refreshes the app tables' triggers, a few per run, so the
-- upgrade itself never holds a lock on the app's tables.
-- Upgrading from 1.4.0, which kept no list: a table whose name EZLogs skips but that has capture
-- triggers was tracked by a person (ezlogs.track). Remember it, so it keeps being recorded.
INSERT INTO ezlogs.tracked (table_oid)
SELECT DISTINCT t.tgrelid FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
 WHERE c.relnamespace = 'public'::regnamespace AND ezlogs.skipped(c.relname)
   AND t.tgname = 'ezlogs_capture' AND t.tgnargs = 6   -- 1.4.0's own trigger (1.5.0's carry a signature too)
   -- never a table named like a secret: 1.4.0 kept recording a table renamed to such a name, which
   -- is no sign a person chose it (hide more when unsure; ezlogs.track records it again)
   AND NOT ezlogs.is_sensitive_key(c.relname)
   AND NOT t.tgisinternal AND t.tgparentid = 0
ON CONFLICT DO NOTHING;

SELECT ezlogs.attach_platform() WHERE ezlogs.connected();
SELECT ezlogs.queue_reconcile();

RESET check_function_bodies;
