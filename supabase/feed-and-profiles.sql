-- Explicit tutor sharing, a public feed, private engagement events and owner analytics.
BEGIN;
ALTER TABLE public.tm_tutor_profiles ADD COLUMN IF NOT EXISTS feed_visible boolean NOT NULL DEFAULT false;
ALTER TABLE public.tm_tutor_statuses ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'update' CHECK(kind IN ('identity','update'));
CREATE UNIQUE INDEX IF NOT EXISTS tm_identity_post ON public.tm_tutor_statuses(profile_id) WHERE kind='identity';
CREATE INDEX IF NOT EXISTS tm_feed_recent ON public.tm_tutor_statuses(created_at DESC,id DESC) WHERE withdrawn_at IS NULL;
CREATE INDEX IF NOT EXISTS tm_shared_profiles ON public.tm_tutor_profiles(id) WHERE feed_visible AND status IN ('pending','approved');
CREATE TABLE IF NOT EXISTS tm_private.tm_feed_reactions(
 post_id uuid NOT NULL REFERENCES public.tm_tutor_statuses(id) ON DELETE CASCADE,
 user_id uuid NOT NULL REFERENCES public.tm_accounts(id) ON DELETE CASCADE,
 created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(post_id,user_id)
);
CREATE INDEX IF NOT EXISTS tm_reaction_user ON tm_private.tm_feed_reactions(user_id);
CREATE TABLE IF NOT EXISTS tm_private.tm_feed_views(
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 profile_id uuid NOT NULL REFERENCES public.tm_tutor_profiles(id) ON DELETE CASCADE,
 post_id uuid REFERENCES public.tm_tutor_statuses(id) ON DELETE CASCADE,
 visitor_hash text NOT NULL CHECK(char_length(visitor_hash)=32),created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS tm_post_unique_visitor ON tm_private.tm_feed_views(post_id,visitor_hash) WHERE post_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS tm_profile_unique_visitor ON tm_private.tm_feed_views(profile_id,visitor_hash) WHERE post_id IS NULL;
CREATE INDEX IF NOT EXISTS tm_view_profile ON tm_private.tm_feed_views(profile_id);
ALTER TABLE tm_private.tm_feed_views ENABLE ROW LEVEL SECURITY;
ALTER TABLE tm_private.tm_feed_reactions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON tm_private.tm_feed_views,tm_private.tm_feed_reactions FROM PUBLIC,anon,authenticated;
GRANT ALL ON tm_private.tm_feed_views,tm_private.tm_feed_reactions TO service_role;
GRANT USAGE,SELECT ON SEQUENCE tm_private.tm_feed_views_id_seq TO service_role;
DROP POLICY IF EXISTS tm_profile_read ON public.tm_tutor_profiles;
CREATE POLICY tm_profile_read ON public.tm_tutor_profiles FOR SELECT TO anon,authenticated USING(status='approved' OR (feed_visible AND status='pending') OR user_id=(SELECT auth.uid()) OR (SELECT public.tm_role())='admin');
DROP POLICY IF EXISTS tm_profile_verified ON public.tm_tutor_profiles;
CREATE POLICY tm_profile_verified ON public.tm_tutor_profiles AS RESTRICTIVE FOR SELECT TO authenticated USING(status='approved' OR (feed_visible AND status='pending') OR (SELECT public.tm_auth_session_ready()));
DROP POLICY IF EXISTS tm_status_read ON public.tm_tutor_statuses;
CREATE POLICY tm_status_read ON public.tm_tutor_statuses FOR SELECT TO anon,authenticated USING((user_id=(SELECT auth.uid()) AND (SELECT public.tm_auth_session_ready())) OR (withdrawn_at IS NULL AND EXISTS(SELECT 1 FROM public.tm_tutor_profiles p WHERE p.id=profile_id AND (p.status='approved' OR (p.feed_visible AND p.status='pending')))));
DROP POLICY IF EXISTS tm_photo_read ON storage.objects;
CREATE POLICY tm_photo_read ON storage.objects FOR SELECT TO anon,authenticated USING(bucket_id='tm-profile-photos' AND (split_part(name,'/',1)=(SELECT auth.uid())::text OR EXISTS(SELECT 1 FROM public.tm_tutor_profiles p WHERE p.photo_path=storage.objects.name AND (p.status='approved' OR (p.feed_visible AND p.status='pending') OR (SELECT public.tm_role())='admin'))));
DROP POLICY IF EXISTS tm_photo_verified ON storage.objects;
CREATE POLICY tm_photo_verified ON storage.objects AS RESTRICTIVE FOR ALL TO authenticated USING(bucket_id!='tm-profile-photos' OR (SELECT public.tm_auth_session_ready()) OR EXISTS(SELECT 1 FROM public.tm_tutor_profiles p WHERE p.photo_path=storage.objects.name AND (p.status='approved' OR (p.feed_visible AND p.status='pending')))) WITH CHECK(bucket_id!='tm-profile-photos' OR (SELECT public.tm_auth_session_ready()));
-- A shared profile must contain at least one introduction, in English or Bengali.
DO $validation$
DECLARE definition text;
BEGIN
 SELECT pg_get_functiondef('tm_private.tm_save_tutor(jsonb,boolean)'::regprocedure) INTO definition;
 definition:=replace(definition,'nullif(trim(p_body->>''aboutEn''),'''') IS NULL OR nullif(trim(p_body->>''aboutBn''),'''') IS NULL','(nullif(trim(p_body->>''aboutEn''),'''') IS NULL AND nullif(trim(p_body->>''aboutBn''),'''') IS NULL)');
 definition:=replace(definition,'days and both introductions','days and an introduction');
 EXECUTE definition;
END $validation$;
CREATE OR REPLACE FUNCTION tm_private.tm_save_shared_profile(p_body jsonb,p_publish boolean,p_consent boolean) RETURNS public.tm_tutor_profiles LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result public.tm_tutor_profiles; message text;
BEGIN
 PERFORM tm_private.tm_assert_verified();
 IF p_publish AND p_consent IS NOT TRUE THEN RAISE EXCEPTION 'Confirm that your teaching details can appear publicly.'; END IF;
 IF p_publish AND (SELECT r.status FROM public.tm_profile_reviews r JOIN public.tm_tutor_profiles p ON p.id=r.profile_id WHERE p.user_id=auth.uid() ORDER BY r.created_at DESC,r.id DESC LIMIT 1)='rejected' THEN RAISE EXCEPTION 'Your profile was returned by an administrator. Save it for review before sharing again.'; END IF;
 result:=tm_private.tm_save_tutor(p_body,p_publish);
 IF NOT p_publish AND (SELECT r.status FROM public.tm_profile_reviews r WHERE r.profile_id=result.id ORDER BY r.created_at DESC,r.id DESC LIMIT 1)='rejected' THEN UPDATE public.tm_tutor_profiles SET status='pending' WHERE id=result.id; END IF;
 UPDATE public.tm_tutor_profiles SET feed_visible=p_publish WHERE id=result.id RETURNING * INTO result;
 IF p_publish THEN
  message:=left(coalesce(nullif(trim(p_body->>'aboutEn'),''),nullif(trim(p_body->>'aboutBn'),''),'Available for tuition')||' · '||array_to_string(result.subjects,', ')||' · '||result.district,1200);
  INSERT INTO public.tm_tutor_statuses(user_id,profile_id,body,kind) VALUES(auth.uid(),result.id,message,'identity')
  ON CONFLICT(profile_id) WHERE kind='identity' DO UPDATE SET body=excluded.body,withdrawn_at=NULL,consent_at=now();
 END IF;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.tm_save_shared_profile(p_body jsonb,p_publish boolean,p_consent boolean DEFAULT false) RETURNS public.tm_tutor_profiles LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_save_shared_profile(p_body,p_publish,p_consent) $$;
CREATE OR REPLACE FUNCTION tm_private.tm_hide_feed_profile() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM tm_private.tm_assert_verified();
 UPDATE public.tm_tutor_profiles SET feed_visible=false WHERE user_id=auth.uid();
 IF NOT FOUND THEN RAISE EXCEPTION 'Create your tutor profile first.'; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.tm_hide_feed_profile() RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_hide_feed_profile() $$;
CREATE OR REPLACE FUNCTION tm_private.tm_feed(p_before timestamptz DEFAULT NULL,p_before_id uuid DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',s.id,'body',s.body,'kind',s.kind,'created_at',s.created_at,'profile',to_jsonb(p)-'user_id','owner',p.user_id=auth.uid(),'reactions',(SELECT count(*) FROM tm_private.tm_feed_reactions r WHERE r.post_id=s.id),'reacted',EXISTS(SELECT 1 FROM tm_private.tm_feed_reactions r WHERE r.post_id=s.id AND r.user_id=auth.uid())) ORDER BY s.created_at DESC,s.id DESC),'[]'::jsonb)
 FROM (SELECT st.* FROM public.tm_tutor_statuses st JOIN public.tm_tutor_profiles pr ON pr.id=st.profile_id WHERE st.withdrawn_at IS NULL AND pr.feed_visible AND pr.status IN ('pending','approved') AND (p_before IS NULL OR st.created_at<p_before OR (st.created_at=p_before AND st.id<p_before_id)) ORDER BY st.created_at DESC,st.id DESC LIMIT 20) s JOIN public.tm_tutor_profiles p ON p.id=s.profile_id
$$;
CREATE OR REPLACE FUNCTION public.tm_feed(p_before timestamptz DEFAULT NULL,p_before_id uuid DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_feed(p_before,p_before_id) $$;
CREATE OR REPLACE FUNCTION tm_private.tm_react_post(p_post uuid,p_reacted boolean) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE owner_id uuid; result bigint;
BEGIN
 PERFORM tm_private.tm_assert_verified();
 SELECT p.user_id INTO owner_id FROM public.tm_tutor_statuses s JOIN public.tm_tutor_profiles p ON p.id=s.profile_id WHERE s.id=p_post AND s.withdrawn_at IS NULL AND p.feed_visible AND p.status IN ('pending','approved');
 IF owner_id IS NULL THEN RAISE EXCEPTION 'This post is no longer available.'; END IF;
 IF owner_id=auth.uid() THEN RAISE EXCEPTION 'Reactions are for other people’s posts.'; END IF;
 IF p_reacted THEN INSERT INTO tm_private.tm_feed_reactions(post_id,user_id) VALUES(p_post,auth.uid()) ON CONFLICT DO NOTHING;
 ELSE DELETE FROM tm_private.tm_feed_reactions WHERE post_id=p_post AND user_id=auth.uid(); END IF;
 SELECT count(*) INTO result FROM tm_private.tm_feed_reactions WHERE post_id=p_post; RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.tm_react_post(p_post uuid,p_reacted boolean) RETURNS bigint LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_react_post(p_post,p_reacted) $$;
CREATE OR REPLACE FUNCTION tm_private.tm_record_view(p_kind text,p_target uuid,p_visitor uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE profile_id uuid; owner_id uuid; hash text;
BEGIN
 IF p_visitor IS NULL OR p_kind IS NULL OR p_kind NOT IN ('post','profile') THEN RAISE EXCEPTION 'Invalid view.'; END IF;
 IF p_kind='post' THEN SELECT p.id,p.user_id INTO profile_id,owner_id FROM public.tm_tutor_statuses s JOIN public.tm_tutor_profiles p ON p.id=s.profile_id WHERE s.id=p_target AND s.withdrawn_at IS NULL AND p.feed_visible AND p.status IN ('pending','approved');
 ELSE SELECT p.id,p.user_id INTO profile_id,owner_id FROM public.tm_tutor_profiles p WHERE p.id=p_target AND (p.status='approved' OR (p.feed_visible AND p.status='pending')); END IF;
 IF profile_id IS NULL OR owner_id=auth.uid() THEN RETURN; END IF;
 -- Anonymous visits use a random browser token; signed-in visitors cannot rotate it.
 hash:=md5(coalesce(auth.uid()::text,p_visitor::text));
 INSERT INTO tm_private.tm_feed_views(profile_id,post_id,visitor_hash) VALUES(profile_id,CASE WHEN p_kind='post' THEN p_target ELSE NULL END,hash) ON CONFLICT DO NOTHING;
END $$;
CREATE OR REPLACE FUNCTION public.tm_record_view(p_kind text,p_target uuid,p_visitor uuid) RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_record_view(p_kind,p_target,p_visitor) $$;
CREATE OR REPLACE FUNCTION tm_private.tm_my_post_analytics() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
 PERFORM tm_private.tm_assert_verified();
 SELECT jsonb_build_object('profileViews',(SELECT count(*) FROM tm_private.tm_feed_views v JOIN public.tm_tutor_profiles p ON p.id=v.profile_id WHERE p.user_id=auth.uid() AND v.post_id IS NULL),'posts',coalesce((SELECT jsonb_agg(jsonb_build_object('id',s.id,'body',s.body,'kind',s.kind,'created_at',s.created_at,'withdrawn_at',s.withdrawn_at,'views',(SELECT count(*) FROM tm_private.tm_feed_views v WHERE v.post_id=s.id),'reactions',(SELECT count(*) FROM tm_private.tm_feed_reactions r WHERE r.post_id=s.id)) ORDER BY s.created_at DESC) FROM public.tm_tutor_statuses s WHERE s.user_id=auth.uid()),'[]'::jsonb)) INTO result;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.tm_my_post_analytics() RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_my_post_analytics() $$;
CREATE OR REPLACE FUNCTION tm_private.tm_edit_post(p_id uuid,p_body text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM tm_private.tm_assert_verified();
 IF char_length(trim(p_body)) NOT BETWEEN 15 AND 1200 THEN RAISE EXCEPTION 'Write 15–1,200 characters.'; END IF;
 UPDATE public.tm_tutor_statuses SET body=trim(p_body) WHERE id=p_id AND user_id=auth.uid();
 IF NOT FOUND THEN RAISE EXCEPTION 'This post does not belong to you.' USING ERRCODE='42501'; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.tm_edit_post(p_id uuid,p_body text) RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_edit_post(p_id,p_body) $$;
DO $permissions$
DECLARE f record;
BEGIN
 FOR f IN SELECT p.oid,n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) args FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('public','tm_private') AND p.proname IN ('tm_save_shared_profile','tm_hide_feed_profile','tm_feed','tm_react_post','tm_record_view','tm_my_post_analytics','tm_edit_post') LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %I.%I(%s) FROM PUBLIC,anon,authenticated',f.nspname,f.proname,f.args);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.%I(%s) TO authenticated',f.nspname,f.proname,f.args);
  IF f.proname IN ('tm_feed','tm_record_view') THEN EXECUTE format('GRANT EXECUTE ON FUNCTION %I.%I(%s) TO anon',f.nspname,f.proname,f.args); END IF;
 END LOOP;
END $permissions$;
NOTIFY pgrst,'reload schema';
COMMIT;
