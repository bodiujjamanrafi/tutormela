-- Permission-only follow-up. Does not create/drop tables or change user records.
BEGIN;
REVOKE ALL ON FUNCTION public.tm_role(),public.tm_catalog_has(text,text),public.tm_valid_choices(text,text[]),public.tm_photo_owned(text),public.tm_update_account(jsonb),public.tm_save_preferences(jsonb),public.tm_save_tutor(jsonb,boolean),public.tm_review_tutor(uuid,text,text),public.tm_send_request(jsonb),public.tm_update_request(uuid,text),public.tm_my_requests() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_role() TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_update_account(jsonb),public.tm_save_preferences(jsonb),public.tm_save_tutor(jsonb,boolean),public.tm_review_tutor(uuid,text,text),public.tm_send_request(jsonb),public.tm_update_request(uuid,text),public.tm_my_requests() TO authenticated;
DO $secure_helpers$
BEGIN
 IF to_regprocedure('public.tm_handle_new_user()') IS NOT NULL THEN EXECUTE 'REVOKE ALL ON FUNCTION public.tm_handle_new_user() FROM PUBLIC,anon,authenticated'; END IF;
 IF to_regprocedure('public.rls_auto_enable()') IS NOT NULL THEN EXECUTE 'REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM PUBLIC,anon,authenticated'; END IF;
END $secure_helpers$;
NOTIFY pgrst, 'reload schema';
COMMIT;
