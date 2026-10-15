-- Apply after schema.sql (or browse-and-plans.sql on an existing installation).
BEGIN;
ALTER TABLE public.tm_accounts ADD COLUMN IF NOT EXISTS tutor_identity jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(tutor_identity)='object' AND octet_length(tutor_identity::text)<=24000);
CREATE OR REPLACE FUNCTION tm_private.tm_save_identity(p_body jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE account public.tm_accounts;
BEGIN
 PERFORM tm_private.tm_assert_verified();
 IF public.tm_role() IS DISTINCT FROM 'tutor' THEN RAISE EXCEPTION 'Tutor account required.' USING ERRCODE='42501'; END IF;
 IF char_length(coalesce(p_body->>'university',''))>200 OR char_length(coalesce(p_body->>'education',''))>200 OR char_length(coalesce(p_body->>'introduction',''))>3000 OR char_length(coalesce(p_body->>'introductionBn',''))>3000 THEN RAISE EXCEPTION 'Profile details are too long.'; END IF;
 SELECT * INTO account FROM public.tm_accounts WHERE id=auth.uid() FOR UPDATE;
 -- Reuse photo ownership, district and name validation. Preserve private contact fields.
 PERFORM tm_private.tm_update_account(jsonb_build_object('name',p_body->>'name','photo_path',p_body->>'photo_path','district',p_body->>'district','phone',account.phone,'learning_goals',account.learning_goals));
 UPDATE public.tm_accounts SET tutor_identity=jsonb_build_object('university',trim(coalesce(p_body->>'university','')),'education',trim(coalesce(p_body->>'education','')),'introduction',trim(coalesce(p_body->>'introduction','')),'introductionBn',trim(coalesce(p_body->>'introductionBn',''))),updated_at=now() WHERE id=auth.uid();
 -- Identity edits never publish or overwrite a teaching post and never consume a slot.
END $$;
CREATE OR REPLACE FUNCTION public.tm_save_identity(p_body jsonb) RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_save_identity(p_body) $$;
REVOKE ALL ON FUNCTION public.tm_save_identity(jsonb),tm_private.tm_save_identity(jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_save_identity(jsonb),tm_private.tm_save_identity(jsonb) TO authenticated;

NOTIFY pgrst,'reload schema';
COMMIT;
