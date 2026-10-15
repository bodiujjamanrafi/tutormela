-- Allow verified account owners to choose the tutor workflow. No posts or accounts are removed.
BEGIN;
CREATE OR REPLACE FUNCTION tm_private.tm_choose_account_role(p_role text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM tm_private.tm_assert_verified();
 IF p_role IS NULL OR p_role NOT IN ('student','tutor') THEN RAISE EXCEPTION 'Choose a student or tutor account.'; END IF;
 -- Verified members may start teaching; this never downgrades tutors or grants admin access.
 UPDATE public.tm_accounts
 SET role=CASE WHEN role='admin' THEN role WHEN p_role='tutor' THEN 'tutor' ELSE role END,
     onboarding_complete=true,updated_at=now()
 WHERE id=auth.uid();
 IF NOT FOUND THEN RAISE EXCEPTION 'Your account could not be found.'; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.tm_choose_account_role(p_role text) RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_choose_account_role(p_role) $$;
REVOKE ALL ON FUNCTION tm_private.tm_choose_account_role(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION tm_private.tm_choose_account_role(text) TO authenticated;
COMMIT;
