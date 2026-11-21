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
| every table in `public` | rows created, changed and deleted, with before and after values. New tables are picked up automatically. |
| `auth.users` | sign-ups, sign-ins, email confirmations, account changes. Only a fixed list of columns is read: never password hashes, tokens or metadata. |
| `storage.objects` | files uploaded, replaced and deleted: bucket, name, size, type and owner |

**Who did it** comes from the login Supabase already verified for the request. That is a
signed-in user, an anonymous visitor, your server using the service key, or an AI connected
through Supabase's OAuth server. Each row also carries your project's auth address (the
token's `iss`), so EZLogs can check logins reported by the browser against your project only.

**Columns named like secrets** (password, token, secret, api_key, card number, cvv, pin, otp, …)
are removed inside the database. They never leave it.

Very large values (over about 1 KB in a big row: an image stored as text, a long document)
are recorded as their size, and a row that is still huge after that as "row too large to
record". Reads are not recorded.

## How it ships

- Changes go into `ezlogs.outbox` and are posted to EZLogs over HTTPS (`pg_net`) when your
  transaction commits, at most once a second.
- A row leaves the outbox only after EZLogs confirmed it. If EZLogs is unreachable, rows wait
  and are retried.
- A small `pg_cron` job exists only while rows are waiting, and removes itself. An idle
  project runs nothing of ours and still pauses normally.
- Disk use is bounded: at most 500,000 waiting rows, kept at most 7 days. Rows dropped for
  that are counted in `ezlogs.status()` and in EZLogs.
- Each post stays under 48 KB, because `pg_net` stalls on bigger request bodies. That allows a
  few hundred changed rows a second, sustained. Bursts above that wait in the outbox.

## Safety

- It never blocks or breaks a write. Every trigger catches its own errors, and a sign-up
  works even if the outbox is broken.
- Nothing is reachable through Supabase's HTTP API: everything lives in its own `ezlogs`
  schema, with no grants to `anon`, `authenticated` or `service_role`.
- Data only goes to `app.ezlogs.io`. That address is part of the code, not a setting.
- The key lives in Supabase Vault. It is an ingest-only key: it can send changes, never read
  anything back. Like every Vault secret it is readable by the database owner and
  `service_role`. It also sits in `pg_net`'s request queue for the moment before a post
  leaves.
- A transaction that writes many rows creates one subtransaction per row. That is the price
  of never failing your write.
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
select ezlogs.uninstall();                 -- remove triggers, job, key and schema
```

### Names for records

A row is named by its own `name`, `title`, `number` or `label` column (or `<table>_number`), the
same as the Rails and Next.js agents; a table with none shows its rows by their short id
(`#b38a…a236`). `ezlogs.name_records('public.<table>', '<column>')` names any table's rows by
another of its columns. For example, `ezlogs.name_records('public.invoices', 'reference')` makes
EZLogs show "Updated invoice 'INV-0042'". It refuses a column named like a secret (never sent), and changes
nothing in your app's writes: the setting is read when rows are sent. Never pick an email or a phone
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
and an uninstall: `cd test && npm install && bash run.sh`.

## License

MIT. See [LICENSE](LICENSE).
