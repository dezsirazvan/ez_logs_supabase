# Changelog

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
