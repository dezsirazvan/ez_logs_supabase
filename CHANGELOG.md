# Changelog

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
