# Changelog

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
