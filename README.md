# EZLogs for Supabase

Record everything your users and your app change in a Supabase database, with who did it,
and read it in [EZLogs](https://ezlogs.io) as plain English: "Ana signed up", "Ana renamed
booking #12", "Bob uploaded contract.pdf".

It runs inside your database, so it works whatever wrote the change: your browser code,
server functions, edge functions, cron, or the dashboard. No app server is needed, which makes
it a fit for apps built with Lovable, Bolt, v0 or by hand.

## Install

One paste, no code in your app:

1. In EZLogs, open **Settings → API keys → Lovable · Bolt · v0** and press **Create install
   code**. The code is this repository's [`sql/install.sql`](sql/install.sql) plus one
   `select ezlogs.connect('ezldb_…');` line carrying your database key.
2. Paste it into your project's **SQL editor** and press **Run**:
   - Lovable: More → Database → Manage → SQL editor;
   - Bolt, v0 or your own project: the Supabase dashboard → SQL Editor.
3. The EZLogs page switches to **Connected** within seconds.

Use the SQL editor, not a chat with your AI builder. The key must not end up in your code or in
git. It is an ingest-only key, but still yours. If your project logs every schema change
(`log_statement = 'ddl'`, pgAudit), the pasted code, key included, lands in your project's own
Postgres logs. Only you can read those. If that matters to you, run the install code without its
last line, then the `connect` line on its own.

**Updating:** run the latest [`sql/install.sql`](sql/install.sql) again, without a connect
line. It upgrades in place and keeps your key and anything still waiting to be sent.

**Keeping it in your migrations?** Add [`sql/install.sql`](sql/install.sql) as a migration;
applying it again later upgrades in place and keeps anything still waiting to be sent. Then run
the connect line once in the SQL editor, never in a migration:

```sql
select ezlogs.connect('ezldb_...');
-- optional second argument: your project URL, e.g. 'https://<project>.supabase.co'
```

It needs the `pg_net`, `pg_cron` and Vault extensions. All three ship with every Supabase and
Lovable Cloud project, and the install enables them. Nothing is recorded until `connect` runs.

## What is recorded

| Where | What |
|---|---|
| every table in `public` | rows created, changed and deleted. A change carries what changed (before and after), plus the row's id and name columns. A statement over 100 rows (an import, a bulk update) is recorded as one bulk change: how many rows, and for an update of up to 10,000 rows which columns it set, with the value when every row got the same one. An update that changes primary keys is recorded as how many rows it changed. New tables are picked up automatically. |
| `auth.users` | sign-ups, sign-ins, email confirmations, account changes. Only a fixed list of columns is read: never password hashes, tokens or metadata. |
| `storage.objects` | files uploaded, replaced and deleted: bucket, name, size, type and owner |

**Who did it** comes from the login Supabase already verified for the request. That is a
signed-in user, an anonymous visitor, your server using the service key, or an AI connected
through Supabase's OAuth server. A change a pg_cron job makes reads as "Scheduled job" (1.5.2).
Each row also carries your project's auth address (the
token's `iss`), so EZLogs can check logins reported by the browser against your project only.

**Columns named like secrets** (password, token, secret, api_key, card number, cvv, pin, otp, …)
are removed inside the database. They never leave it.

Large values are recorded as their size and never read: binary data, vectors (embeddings) and
search columns always, and any other value stored over 8 KB. In a big row, values over about
1 KB are cut the same way, and a row that is still huge after that is "row too large to
record". Reads are not recorded.

**Columns you leave out** (a heartbeat such as `last_seen_at` that changes on every page load):
`select ezlogs.ignore_columns('public.profiles', ARRAY['last_seen_at']);`. They are never sent,
and an update that changed only them is not recorded.

## How it ships

- Changes go into `ezlogs.outbox` and are posted to EZLogs over HTTPS (`pg_net`) when your
  transaction commits, at most once a second.
- A row leaves the outbox only after EZLogs confirmed it. If EZLogs is unreachable, rows wait
  and are retried.
- A small `pg_cron` job exists only while rows are waiting, and removes itself. An idle
  project runs nothing of ours and still pauses normally.
- Disk use is bounded: at most 500,000 waiting rows, kept at most 7 days. Rows dropped for
  that are counted in `ezlogs.status()` and in EZLogs.
- It can never fill your database: when the waiting rows pass 5% of the database (at least
  10 MB, at most 50 MB), recording pauses until they drain to half. Changes made meanwhile are not
  recorded, and EZLogs shows the pause on its install page. It also pauses after an hour of
  EZLogs refusing the key (revoked, or the plan stopped), and resumes once EZLogs accepts it
  again or you run `connect` with a new key.
- Each post stays under 48 KB, because `pg_net` stalls on bigger request bodies. Up to 25
  posts go out every 5 seconds while a backlog waits (about 45,000 changes a minute), and each post says how many wait, so
  EZLogs shows how far behind it is.

## Safety

- It never blocks or breaks a write. Every trigger catches its own errors, and a sign-up
  works even if the outbox is broken.
- It records once per statement, not once per row: a table with a one-column primary key gets
  three statement triggers (insert, update, delete) and capture functions made for that table.
  An import of 100,000 rows adds milliseconds, not seconds. A table without a one-column key, and
  a partitioned table (so writes made straight to a partition are seen), keep one trigger per row.
- A statement over 100 rows keeps its rows in Postgres's temporary files until it ends (the price
  of recording it once): a mass update of a large table needs temporary disk about the size of
  the rows it changes, twice.
- Installing, upgrading and connecting never lock your tables for long: tables are attached by
  the background job, 10 at a time, each waiting at most 100 ms for its lock.
- Nothing is reachable through Supabase's HTTP API: everything lives in its own `ezlogs`
  schema, with no grants to `anon`, `authenticated` or `service_role`.
- Data only goes to `app.ezlogs.io`. That address is part of the code, not a setting.
- The key lives in Supabase Vault. It is an ingest-only key: it can send changes, never read
  anything back. Like every Vault secret it is readable by the database owner and
  `service_role`. It also sits in `pg_net`'s request queue for the moment before a post
  leaves.
- A `SERIALIZABLE` transaction ships nothing itself, to avoid conflicts with your
  transaction. Its rows go out with the next other write. If every write in your app is
  serializable, run `select ezlogs.ensure_flush_job();` after writing.

## Manage

```sql
select ezlogs.status();                    -- connected? waiting rows? last error?
select ezlogs.untrack('public.audit_noise');  -- stop recording a table (stays off)
select ezlogs.track('public.audit_noise');    -- record it again
select ezlogs.name_records('public.<table>', '<column>');  -- name that table's rows by that column
select ezlogs.name_records('public.<table>', NULL);        -- back to the default columns
select ezlogs.ignore_columns('public.<table>', ARRAY['<column>']);  -- never send these columns
select ezlogs.ignore_columns('public.<table>', NULL);              -- send them again
select ezlogs.uninstall();                 -- remove triggers, job, key and schema
```

### Names for records

A row is named by its own `name`, `title`, `number` or `label` column (or `<table>_number`), the
same as the Rails and Next.js agents; a table with none shows its rows by their short id
(`#b38a…a236`). `ezlogs.name_records('public.<table>', '<column>')` names any table's rows by
another of its columns. For example, `ezlogs.name_records('public.invoices', 'reference')` makes
EZLogs show "Updated invoice 'INV-0042'". It refuses a column named like a secret (never sent). It rebuilds
that table's capture once, so every change carries the name column. Never pick an email or a phone
number: names show on shared links. In a migration, guard it so a copy of the project without
EZLogs still applies:

```sql
DO $$ BEGIN
  IF to_regprocedure('ezlogs.name_records(text,text)') IS NOT NULL AND to_regclass('public.<table>') IS NOT NULL THEN
    PERFORM ezlogs.name_records('public.<table>', '<column>');
  END IF;
  -- one IF block per table
END $$;
```

## Tests

`test/run.sh` runs the install against a local Supabase stack (Docker and the supabase CLI). It
drives real sign-ups, uploads, refused writes, outages, a revoked key, bursts, concurrent writers
and an uninstall: `cd test && npm install && bash run.sh`. `bash upgrade.sh` upgrades each earlier
release, holding rows it could not send yet, and checks every row arrives exactly once (monorepo checkout only).

`test/load.sh` measures what capture adds to an app's writes. With 100,000 rows on a laptop
(1.5.0, against 1.4.0): an insert +0.02 s (was +4.2 s), an update of every row +0.02 s (was
+3.9 s), a delete +0.02 s (was +3.2 s), 2,000 single-row updates +0.1 s (unchanged). `INSTALL=<file>`
compares another version.

## License

MIT. See [LICENSE](LICENSE).
