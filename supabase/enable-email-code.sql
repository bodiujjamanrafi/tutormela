-- Apply only after configuring and testing email-login-code SMTP secrets.
-- This activates database-enforced verification for email/password sessions.
-- Google/Facebook OAuth sessions use the provider's verified sign-in instead.
UPDATE tm_private.tm_auth_config SET email_code_enabled=true WHERE id=true;
