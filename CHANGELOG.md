# Changelog

## 1.5.1

- A password change and a password-reset request now show in EZLogs. `auth.users` keeps its
  fixed column list (still no hash, no token); an update of the password sends only
  `pw_changed: true`, and `recovery_sent_at` (when Auth sent a reset email) joins the list.
  An update touching only tokens still records nothing.
