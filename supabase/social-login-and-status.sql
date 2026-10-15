-- Supabase-backed social onboarding, tutor status posts and optional 4-digit email verification.
-- Run after schema.sql. Safe to rerun; no user records are dropped.
BEGIN;
CREATE TABLE IF NOT EXISTS tm_private.tm_auth_config(id boolean PRIMARY KEY DEFAULT true CHECK(id),email_code_enabled boolean NOT NULL DEFAULT false);
INSERT INTO tm_private.tm_auth_config(id) VALUES(true) ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS tm_private.tm_login_challenges(
 user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
 session_id uuid NOT NULL REFERENCES auth.sessions(id) ON DELETE CASCADE,
 code_hash text,expires_at timestamptz NOT NULL,attempts integer NOT NULL DEFAULT 0,
 delivered boolean NOT NULL DEFAULT false,last_sent_at timestamptz NOT NULL DEFAULT now(),
 window_start timestamptz NOT NULL DEFAULT now(),send_count integer NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS tm_private.tm_verified_sessions(
 session_id uuid PRIMARY KEY REFERENCES auth.sessions(id) ON DELETE CASCADE,
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,verified_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS tm_verified_session_user ON tm_private.tm_verified_sessions(user_id);
CREATE INDEX IF NOT EXISTS tm_challenge_session ON tm_private.tm_login_challenges(session_id);
ALTER TABLE tm_private.tm_auth_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE tm_private.tm_login_challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE tm_private.tm_verified_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON tm_private.tm_auth_config,tm_private.tm_login_challenges,tm_private.tm_verified_sessions FROM PUBLIC,anon,authenticated;
DROP POLICY IF EXISTS tm_no_client_access ON tm_private.tm_auth_config;
CREATE POLICY tm_no_client_access ON tm_private.tm_auth_config FOR ALL TO anon,authenticated USING(false) WITH CHECK(false);
DROP POLICY IF EXISTS tm_no_client_access ON tm_private.tm_login_challenges;
CREATE POLICY tm_no_client_access ON tm_private.tm_login_challenges FOR ALL TO anon,authenticated USING(false) WITH CHECK(false);
DROP POLICY IF EXISTS tm_no_client_access ON tm_private.tm_verified_sessions;
CREATE POLICY tm_no_client_access ON tm_private.tm_verified_sessions FOR ALL TO anon,authenticated USING(false) WITH CHECK(false);
CREATE OR REPLACE FUNCTION tm_private.tm_email_code_enabled() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT email_code_enabled FROM tm_private.tm_auth_config WHERE id $$;
CREATE OR REPLACE FUNCTION public.tm_email_code_enabled() RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_email_code_enabled() $$;
CREATE OR REPLACE FUNCTION tm_private.tm_auth_session_ready() RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE sid uuid; claims jsonb:=auth.jwt();
BEGIN
 IF auth.uid() IS NULL THEN RETURN false; END IF;
 IF NOT tm_private.tm_email_code_enabled() THEN RETURN true; END IF;
 sid:=nullif(claims->>'session_id','')::uuid;
 IF sid IS NULL OR NOT EXISTS(SELECT 1 FROM auth.sessions s WHERE s.id=sid AND s.user_id=auth.uid()) THEN RETURN false; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(coalesce(claims->'amr','[]')) a WHERE a->>'method'='oauth') AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(coalesce(claims->'amr','[]')) a WHERE a->>'method'='password') THEN RETURN true; END IF;
 RETURN EXISTS(SELECT 1 FROM tm_private.tm_verified_sessions v WHERE v.session_id=sid AND v.user_id=auth.uid());
END $$;
CREATE OR REPLACE FUNCTION public.tm_auth_session_ready() RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_auth_session_ready() $$;
CREATE OR REPLACE FUNCTION tm_private.tm_assert_verified() RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$ BEGIN IF NOT tm_private.tm_auth_session_ready() THEN RAISE EXCEPTION 'Verify your email code before opening your account.' USING ERRCODE='42501'; END IF; RETURN true; END $$;

-- Only the authenticated Edge Function's server client can issue or check codes.
CREATE OR REPLACE FUNCTION tm_private.tm_issue_email_code(p_user uuid,p_session uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE old tm_private.tm_login_challenges; start_at timestamptz; n integer;
BEGIN
 IF p_hash IS NULL OR p_hash !~ '^[a-f0-9]{64}$' OR NOT EXISTS(SELECT 1 FROM auth.sessions WHERE id=p_session AND user_id=p_user) THEN RAISE EXCEPTION 'Invalid authenticated session.'; END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user::text,0));
 SELECT * INTO old FROM tm_private.tm_login_challenges WHERE user_id=p_user FOR UPDATE;
 IF FOUND AND old.last_sent_at>now()-interval '60 seconds' THEN RETURN jsonb_build_object('ok',false,'error','Wait one minute before requesting another code.'); END IF;
 start_at:=CASE WHEN old.window_start>now()-interval '1 hour' THEN old.window_start ELSE now() END;
 n:=CASE WHEN old.window_start>now()-interval '1 hour' THEN old.send_count+1 ELSE 1 END;
 IF n>5 THEN RETURN jsonb_build_object('ok',false,'error','Too many code requests. Try again in one hour.'); END IF;
 INSERT INTO tm_private.tm_login_challenges(user_id,session_id,code_hash,expires_at,attempts,delivered,last_sent_at,window_start,send_count)
 VALUES(p_user,p_session,p_hash,now()+interval '5 minutes',0,false,now(),start_at,n)
 ON CONFLICT(user_id) DO UPDATE SET session_id=excluded.session_id,code_hash=excluded.code_hash,expires_at=excluded.expires_at,attempts=0,delivered=false,last_sent_at=now(),window_start=excluded.window_start,send_count=excluded.send_count;
 RETURN jsonb_build_object('ok',true,'expiresAt',now()+interval '5 minutes','resendAfter',60);
END $$;
CREATE OR REPLACE FUNCTION public.tm_issue_email_code(p_user uuid,p_session uuid,p_hash text) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_issue_email_code(p_user,p_session,p_hash) $$;
CREATE OR REPLACE FUNCTION tm_private.tm_mark_code_delivered(p_user uuid,p_session uuid) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$ UPDATE tm_private.tm_login_challenges SET delivered=true WHERE user_id=p_user AND session_id=p_session $$;
CREATE OR REPLACE FUNCTION public.tm_mark_code_delivered(p_user uuid,p_session uuid) RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_mark_code_delivered(p_user,p_session) $$;
CREATE OR REPLACE FUNCTION tm_private.tm_verify_email_code(p_user uuid,p_session uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c tm_private.tm_login_challenges;
BEGIN
 IF p_hash IS NULL OR p_hash !~ '^[a-f0-9]{64}$' THEN RETURN jsonb_build_object('verified',false,'error','Invalid verification code.'); END IF;
 SELECT * INTO c FROM tm_private.tm_login_challenges WHERE user_id=p_user FOR UPDATE;
 IF NOT FOUND OR c.session_id<>p_session OR NOT c.delivered OR c.expires_at<=now() OR c.code_hash IS NULL THEN RETURN jsonb_build_object('verified',false,'error','This code has expired. Request a new code.'); END IF;
 IF c.attempts>=5 THEN RETURN jsonb_build_object('verified',false,'error','Too many attempts. Request a new code.'); END IF;
 UPDATE tm_private.tm_login_challenges SET attempts=attempts+1 WHERE user_id=p_user;
 IF c.code_hash<>p_hash THEN RETURN jsonb_build_object('verified',false,'error','The code is incorrect. Check your email and try again.'); END IF;
 IF NOT EXISTS(SELECT 1 FROM auth.sessions WHERE id=p_session AND user_id=p_user) THEN RETURN jsonb_build_object('verified',false,'error','Your sign-in session has expired.'); END IF;
 INSERT INTO tm_private.tm_verified_sessions(session_id,user_id) VALUES(p_session,p_user) ON CONFLICT DO NOTHING;
 UPDATE tm_private.tm_login_challenges SET code_hash=NULL,expires_at=now() WHERE user_id=p_user;
 RETURN jsonb_build_object('verified',true);
END $$;
CREATE OR REPLACE FUNCTION public.tm_verify_email_code(p_user uuid,p_session uuid,p_hash text) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_verify_email_code(p_user,p_session,p_hash) $$;

ALTER TABLE public.tm_accounts ADD COLUMN IF NOT EXISTS onboarding_complete boolean NOT NULL DEFAULT true;
CREATE OR REPLACE FUNCTION tm_private.tm_handle_new_user() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 INSERT INTO public.tm_accounts(id,name,role,onboarding_complete) VALUES(NEW.id,left(coalesce(nullif(trim(NEW.raw_user_meta_data->>'name'),''),nullif(trim(NEW.raw_user_meta_data->>'full_name'),''),split_part(NEW.email,'@',1),'Member'),80),CASE WHEN NEW.raw_app_meta_data->>'provider' IN ('google','facebook') THEN 'student' WHEN NEW.raw_user_meta_data->>'role'='tutor' THEN 'tutor' ELSE 'student' END,coalesce(NEW.raw_app_meta_data->>'provider','email') NOT IN ('google','facebook')) ON CONFLICT(id) DO NOTHING;
 RETURN NEW;
END $$;
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

CREATE TABLE IF NOT EXISTS public.tm_tutor_statuses(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid NOT NULL REFERENCES public.tm_accounts(id) ON DELETE CASCADE,
 profile_id uuid NOT NULL REFERENCES public.tm_tutor_profiles(id) ON DELETE CASCADE,
 body text NOT NULL CHECK(char_length(trim(body)) BETWEEN 15 AND 1200),
 consent_at timestamptz NOT NULL DEFAULT now(),created_at timestamptz NOT NULL DEFAULT now(),withdrawn_at timestamptz
);
CREATE INDEX IF NOT EXISTS tm_status_profile ON public.tm_tutor_statuses(profile_id,created_at DESC);
CREATE INDEX IF NOT EXISTS tm_status_owner ON public.tm_tutor_statuses(user_id,created_at DESC);
ALTER TABLE public.tm_tutor_statuses ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tm_status_read ON public.tm_tutor_statuses;
CREATE POLICY tm_status_read ON public.tm_tutor_statuses FOR SELECT TO anon,authenticated USING((user_id=(SELECT auth.uid()) AND (SELECT public.tm_auth_session_ready())) OR (withdrawn_at IS NULL AND EXISTS(SELECT 1 FROM public.tm_tutor_profiles p WHERE p.id=profile_id AND p.status='approved')));
REVOKE ALL ON public.tm_tutor_statuses FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.tm_tutor_statuses TO anon,authenticated;
GRANT ALL ON public.tm_tutor_statuses TO service_role;
CREATE OR REPLACE FUNCTION tm_private.tm_post_tutor_status(p_body text,p_consent boolean) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE profile uuid; result uuid;
BEGIN
 PERFORM tm_private.tm_assert_verified();
 IF public.tm_role() IS DISTINCT FROM 'tutor' THEN RAISE EXCEPTION 'Only tutor accounts can publish availability updates.' USING ERRCODE='42501'; END IF;
 IF p_consent IS NOT TRUE THEN RAISE EXCEPTION 'Confirm that your status can appear publicly.'; END IF;
 SELECT id INTO profile FROM public.tm_tutor_profiles WHERE user_id=auth.uid();
 IF profile IS NULL THEN RAISE EXCEPTION 'Create your teaching profile before posting a status.'; END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(auth.uid()::text,1));
 IF EXISTS(SELECT 1 FROM public.tm_tutor_statuses WHERE user_id=auth.uid() AND created_at>now()-interval '1 minute') THEN RAISE EXCEPTION 'Wait one minute before posting another update.'; END IF;
 IF (SELECT count(*) FROM public.tm_tutor_statuses WHERE user_id=auth.uid() AND created_at>now()-interval '1 day')>=12 THEN RAISE EXCEPTION 'You can post up to 12 updates in one day.'; END IF;
 INSERT INTO public.tm_tutor_statuses(user_id,profile_id,body) VALUES(auth.uid(),profile,trim(p_body)) RETURNING id INTO result;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.tm_post_tutor_status(p_body text,p_consent boolean) RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_post_tutor_status(p_body,p_consent) $$;
CREATE OR REPLACE FUNCTION tm_private.tm_set_status_visibility(p_id uuid,p_visible boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM tm_private.tm_assert_verified();
 UPDATE public.tm_tutor_statuses SET withdrawn_at=CASE WHEN p_visible THEN NULL ELSE now() END WHERE id=p_id AND user_id=auth.uid();
 IF NOT FOUND THEN RAISE EXCEPTION 'This status does not belong to your account.' USING ERRCODE='42501'; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.tm_set_status_visibility(p_id uuid,p_visible boolean) RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_set_status_visibility(p_id,p_visible) $$;

-- Apply the email-session gate to existing action functions without changing their behavior.
DO $gate_actions$
DECLARE f record; definition text;
BEGIN
 FOR f IN SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='tm_private' AND p.proname IN ('tm_update_account','tm_save_preferences','tm_save_tutor','tm_review_tutor','tm_send_request','tm_update_request') LOOP
  definition:=pg_get_functiondef(f.oid);
  IF position('PERFORM tm_private.tm_assert_verified();' IN definition)=0 THEN EXECUTE replace(definition,E'BEGIN\n',E'BEGIN\n PERFORM tm_private.tm_assert_verified();\n'); END IF;
 END LOOP;
END $gate_actions$;

CREATE OR REPLACE FUNCTION tm_private.tm_my_requests() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$ BEGIN PERFORM tm_private.tm_assert_verified(); RETURN (SELECT coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('tutor_name',p.name) ORDER BY r.created_at DESC),'[]'::jsonb)
 FROM public.tm_contact_requests r JOIN public.tm_tutor_profiles p ON p.id=r.profile_id
 WHERE (public.tm_role()='student' AND r.student_id=auth.uid()) OR (public.tm_role()='tutor' AND p.user_id=auth.uid())); END $$;
DROP POLICY IF EXISTS tm_verified_access ON public.tm_accounts;
CREATE POLICY tm_verified_access ON public.tm_accounts AS RESTRICTIVE FOR ALL TO authenticated USING((SELECT public.tm_auth_session_ready())) WITH CHECK((SELECT public.tm_auth_session_ready()));
DROP POLICY IF EXISTS tm_verified_access ON public.tm_profile_reviews;
CREATE POLICY tm_verified_access ON public.tm_profile_reviews AS RESTRICTIVE FOR ALL TO authenticated USING((SELECT public.tm_auth_session_ready())) WITH CHECK((SELECT public.tm_auth_session_ready()));
DROP POLICY IF EXISTS tm_verified_access ON public.tm_saved_tutors;
CREATE POLICY tm_verified_access ON public.tm_saved_tutors AS RESTRICTIVE FOR ALL TO authenticated USING((SELECT public.tm_auth_session_ready())) WITH CHECK((SELECT public.tm_auth_session_ready()));
DROP POLICY IF EXISTS tm_verified_access ON public.tm_contact_requests;
CREATE POLICY tm_verified_access ON public.tm_contact_requests AS RESTRICTIVE FOR ALL TO authenticated USING((SELECT public.tm_auth_session_ready())) WITH CHECK((SELECT public.tm_auth_session_ready()));
DROP POLICY IF EXISTS tm_verified_access ON public.tm_audit_log;
CREATE POLICY tm_verified_access ON public.tm_audit_log AS RESTRICTIVE FOR ALL TO authenticated USING((SELECT public.tm_auth_session_ready())) WITH CHECK((SELECT public.tm_auth_session_ready()));
DROP POLICY IF EXISTS tm_profile_verified ON public.tm_tutor_profiles;
CREATE POLICY tm_profile_verified ON public.tm_tutor_profiles AS RESTRICTIVE FOR SELECT TO authenticated USING(status='approved' OR (SELECT public.tm_auth_session_ready()));
DROP POLICY IF EXISTS tm_photo_verified ON storage.objects;
CREATE POLICY tm_photo_verified ON storage.objects AS RESTRICTIVE FOR ALL TO authenticated USING(bucket_id!='tm-profile-photos' OR (SELECT public.tm_auth_session_ready()) OR EXISTS(SELECT 1 FROM public.tm_tutor_profiles p WHERE p.photo_path=storage.objects.name AND p.status='approved')) WITH CHECK(bucket_id!='tm-profile-photos' OR (SELECT public.tm_auth_session_ready()));
GRANT USAGE ON SCHEMA tm_private TO service_role;
REVOKE ALL ON FUNCTION public.tm_email_code_enabled() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_email_code_enabled() TO anon,authenticated;
REVOKE ALL ON FUNCTION tm_private.tm_email_code_enabled() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION tm_private.tm_email_code_enabled() TO anon,authenticated;
REVOKE ALL ON FUNCTION public.tm_auth_session_ready() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_auth_session_ready() TO anon,authenticated;
REVOKE ALL ON FUNCTION tm_private.tm_auth_session_ready() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION tm_private.tm_auth_session_ready() TO anon,authenticated;
REVOKE ALL ON FUNCTION public.tm_issue_email_code(uuid,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_issue_email_code(uuid,uuid,text) TO service_role;
REVOKE ALL ON FUNCTION tm_private.tm_issue_email_code(uuid,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION tm_private.tm_issue_email_code(uuid,uuid,text) TO service_role;
REVOKE ALL ON FUNCTION public.tm_mark_code_delivered(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_mark_code_delivered(uuid,uuid) TO service_role;
REVOKE ALL ON FUNCTION tm_private.tm_mark_code_delivered(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION tm_private.tm_mark_code_delivered(uuid,uuid) TO service_role;
REVOKE ALL ON FUNCTION public.tm_verify_email_code(uuid,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_verify_email_code(uuid,uuid,text) TO service_role;
REVOKE ALL ON FUNCTION tm_private.tm_verify_email_code(uuid,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION tm_private.tm_verify_email_code(uuid,uuid,text) TO service_role;
REVOKE ALL ON FUNCTION public.tm_choose_account_role(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_choose_account_role(text) TO authenticated;
REVOKE ALL ON FUNCTION tm_private.tm_choose_account_role(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION tm_private.tm_choose_account_role(text) TO authenticated;
REVOKE ALL ON FUNCTION public.tm_post_tutor_status(text,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_post_tutor_status(text,boolean) TO authenticated;
REVOKE ALL ON FUNCTION tm_private.tm_post_tutor_status(text,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION tm_private.tm_post_tutor_status(text,boolean) TO authenticated;
REVOKE ALL ON FUNCTION public.tm_set_status_visibility(uuid,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_set_status_visibility(uuid,boolean) TO authenticated;
REVOKE ALL ON FUNCTION tm_private.tm_set_status_visibility(uuid,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION tm_private.tm_set_status_visibility(uuid,boolean) TO authenticated;
REVOKE ALL ON FUNCTION tm_private.tm_assert_verified() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION tm_private.tm_assert_verified() TO authenticated;
REVOKE ALL ON FUNCTION tm_private.tm_handle_new_user() FROM PUBLIC,anon,authenticated;
NOTIFY pgrst, 'reload schema';
COMMIT;
