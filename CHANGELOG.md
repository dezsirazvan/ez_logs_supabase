# Changelog

## 1.6.0

- **Phone numbers, addresses, birth dates, IP addresses and identity-document numbers never leave
  the database.** A change to one is still sent, without its values, so EZLogs reads "Ana changed
  her phone" (or "set", "removed"), never the number. The same rule runs on the EZLogs server
  (which masks these on arrival for older installs too), in the Rails agent 0.2.24 and in
  ezlogs-nextjs 0.4.18, checked against one shared list of column names
  (`test/personal_key_vectors.json`):
  - **By name** (`ezlogs.is_personal_key`): a column or json key with the word `phone`,
    `telephone`, `mobile` (alone or as a number), `fax`, `msisdn`, `address` (not `email_address`),
    `addr`, `street`, `line1`…, `house_number`, `postcode` / `postal_code` / `zip` / `zip_code`,
    `birth` / `birthday` / `born` / `dob`, `passport`, `ip` / `ips` / `ipv4` / `ipv6` /
    `remote_addr` / `forwarded_for`, `latitude` / `longitude` / `lat` / `lng`, or a tax, VAT,
    national, ID-card, document, fiscal or driver's licence number. Not a column that ends in `id`,
    `ids`, `uuid`, `type`, `kind`, `count`, `at`, `status`, `state`, `verified` or `confirmed`
    (`address_id`, `phone_confirmed_at`, `phone_status` stay), nor one naming an email (unless a
    phone shares it: `email_or_phone`). `auth.users`' `phone` too.
  - **By table** (`ezlogs.is_personal_table`): a table that is a list of phones, addresses or IPs
    (`phone_numbers`, `user_addresses`) has its value columns treated the same way (its `number` is
    the phone), its rows are never named by their values, and its pre-install names are not sent.
  - **Values** become `[redacted]`; `null`, blank strings and booleans are kept. In an update, a
    personal value that did not change is left out of both sides, so two masked sides always mean
    it changed; inside json values, the same at every depth. A bulk update's summary says a personal
    column `{"changed": true}`, never its value.
  - **Where:** as each row is sent (`ezlogs.row_json`). Capture is unchanged: the raw value sits only
    in this database's own `ezlogs.outbox` until its row is sent, and no table re-attaches on upgrade.
    A post is now sized from the rows as captured (`ezlogs.row_bytes`) and masked only for the rows it
    sends; one that grew past the limit sends half its rows.
  - `ezlogs.name_records` refuses a personal column ("holds personal data"); one chosen with an
    earlier version is no longer sent, and those rows are named by their default columns again.
  What this costs, on purpose: a business's own address or phone (a venue's street) is hidden too,
  since the rule reads names, not intent; searching EZLogs for a phone number finds nothing. Leave
  out more with `ezlogs.ignore_columns` or `ezlogs.untrack`; there is no switch to send these values.

## 1.5.5

- **More credential names are never sent.** A column (or a key inside json) whose name contains
  `jwt`, `webhook_url` (a Slack or Discord webhook), `connection_string`, `database_url`, `access_key`, `auth_key`, `session_key`, `license_key`, `encryption_key`, `ssh_key`, `master_key`, `mnemonic`, `seed_phrase`, `auth_code`, `reset_code`, `invite_code`, `magic_link`, and `dsn` as a whole word is left out, as `password` and `token` always were; a table named like one is not
  recorded. Same list as ezlogs-nextjs 0.4.17, the Rails agent 0.2.23 and the EZLogs server, which
  masks them on arrival for older installs too. Tables re-attach on their own (`patterns_version`
  `p3`), a few per flush run.
- **No warnings in Supabase's Security Advisor.** Every `ezlogs` function now pins its
  `search_path` (lint `function_search_path_mutable`); nothing was reachable before (the schema is
  closed to the API roles), but the Advisor listed about 30 warnings.
- **Attaching tables never waits behind the cron history.** The flush job trims its own run history
  (`cron.job_run_details` has no index on `jobid`, so that reads the whole table) before it takes
  the locks attaching tables needs, not while holding them.
- **`ezlogs.uninstall()` and tracking `auth.users` / `storage.objects` wait at most 2 seconds for a
  busy table.** Uninstall then stops without removing anything ("run it again in a moment"); a
  platform table is tried again later. Before, they could wait as long as the table was held, and
  the app's queries on it queued behind them.
- **`ezlogs.uninstall()` also removes its own job's run history** (`cron.job_run_details` rows of
  `ezlogs-flush`), and says what stays: your data, and pg_cron and pg_net (other features may use them).
- `connect()` with a key that isn't a database key names the page by its new name (Install & keys).
- The file says at the top why your editor warns about DELETE and DROP: each one touches only
  EZLogs' own rows, job history, functions, triggers, key and schema.

## 1.5.4

- Rows that existed before the install are named. EZLogs learned a row's name only from a change
  it captured, so a new booking of a class nobody changed since read "Created booking #67ab…6d59".
  Once, from the flush job after `connect()`, the install sends the id and name of existing rows
  of each tracked table another app table points to by a foreign key (the classes bookings point
  to), as rows of schema `ezlogs`, table `record_names`: `{table, id, name}`, nothing else. The
  name is the column EZLogs names that table's rows by (`ezlogs.name_records`, else `name`,
  `title`, `number`, `label`, `<record>_number`), never a column named like a secret or one left
  out with `ignore_columns`. Left out: a table with one row per sign-in account (a foreign key to
  `auth.users` on a column unique on its own: `profiles.id`, a `user_id UNIQUE`; a plain
  `created_by` pointing there does not count), one named like people or the accounts they belong to (whole name or last word, singular:
  the server's person and tenant nouns, `members`, `customers`, `team_members`, `companies`), and
  one with a column for a person's name, email or phone. A name list can't recognise every table
  of people (`coaches`, `students`): leave any table out with `select ezlogs.untrack('public.<table>');`.
  At most 1,000 rows per table (the highest keys, read through the primary key) and 10,000 in
  all, small tables first. Sent once per install (`ezlogs.names_sent`, `ezlogs.state.names_sent_at`):
  a table a migration holds locked is tried again at the next reconcile, and re-applying the
  file or running `connect` again sends nothing more; an install upgraded from 1.5.3 sends them
  once, at its next flush. EZLogs keeps them, until the account is deleted, only to name those rows from that moment on
  (the newest name it knows at the time of an action wins): no action, no Timeline entry, no alert,
  no count, and an action before the install is never renamed. Servers older than this skip
  such rows.

## 1.5.3

- A database that never ran `ezlogs.connect()` records nothing. A Supabase branch, a preview, a
  `db reset` or a staging copy that applies this file (and `name_records`, `ignore_columns` or
  `track`) but never connects used to fill `ezlogs.outbox` with rows nothing would ship or trim.
- Renaming a column re-attaches its table at once. The schema-change trigger missed
  `ALTER TABLE ... RENAME COLUMN` (reported as a 'table column'), so the table's capture failed
  (the write still succeeded) until the flush job's next re-attach.
- A table with old-style INHERITS parents or children is captured row by row. Since 1.5.0 a write
  through the parent recorded a child's rows twice, or under the parent's name (the parent's
  statement capture sees them, and so may the child's own capture); now each row is recorded once,
  under its own table. A table the schema-change trigger or the flush job could not lock at once
  is tried again on the flush job's next run (5 seconds), not 10 minutes later.

## 1.5.2

- A change made by a pg_cron job now shows who made it: EZLogs names it "Scheduled job"
  instead of nobody. A write with no login and no server-agent actor, made in a pg_cron
  session (`application_name` 'pg_cron'), sends `claims: {"scheduler": "pg_cron"}`. Writes
  with a login are unchanged; other writes without one still send no claims.

## 1.5.1

- A password change and a password-reset request now show in EZLogs. `auth.users` keeps its
  fixed column list (still no hash, no token); an update of the password sends only
  `pw_changed: true`, and `recovery_sent_at` (when Auth sent a reset email) joins the list.
  An update touching only tokens still records nothing.
