-- Run as project owner in the Supabase SQL Editor.
-- Replace the email below with the intended administrator's registered email.
DO $$
DECLARE
 target_email text := 'your-registered-email@example.com';
 moderator_id uuid;
 confirmed_at timestamptz;
BEGIN
 IF target_email = 'your-registered-email@example.com' OR trim(target_email) = '' THEN
  RAISE NOTICE 'Replace target_email with your registered, verified email. No account was changed.';
  RETURN;
 END IF;
 SELECT id, email_confirmed_at INTO moderator_id, confirmed_at
 FROM auth.users WHERE lower(email) = lower(trim(target_email));
 IF moderator_id IS NULL THEN
  RAISE NOTICE 'No registered account found for %. No account was changed.', target_email;
  RETURN;
 END IF;
 IF confirmed_at IS NULL THEN
  RAISE NOTICE 'Verify the account email first. No account was changed.';
  RETURN;
 END IF;
 UPDATE public.tm_accounts SET role = 'admin', updated_at = now()
 WHERE id = moderator_id;
 IF NOT FOUND THEN
  RAISE NOTICE 'Application account is missing. Run schema.sql first.';
  RETURN;
 END IF;
 RAISE NOTICE 'Administrator access granted to %.', target_email;
END $$;
