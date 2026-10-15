-- Durable shared tutor posts, social likes and administrator-only removal.
BEGIN;
CREATE OR REPLACE FUNCTION tm_private.tm_preserve_shared_content() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL OR public.tm_role()='admin' THEN RETURN NEW; END IF;
 IF TG_TABLE_NAME='tm_tutor_profiles' THEN
  IF OLD.feed_visible THEN
   IF NEW.feed_visible IS DISTINCT FROM true THEN RAISE EXCEPTION 'Only administrators can remove shared profiles.' USING ERRCODE='42501'; END IF;
   IF OLD.status='rejected' THEN NEW.status:='rejected';
   ELSIF NEW.status='draft' THEN RAISE EXCEPTION 'Update the shared profile instead of making it private.' USING ERRCODE='42501'; END IF;
  END IF;
 ELSE
  IF NEW.withdrawn_at IS DISTINCT FROM OLD.withdrawn_at THEN RAISE EXCEPTION 'Only administrators can remove or restore posts.' USING ERRCODE='42501'; END IF;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION tm_private.tm_preserve_shared_content() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS tm_preserve_shared_profile ON public.tm_tutor_profiles;
CREATE TRIGGER tm_preserve_shared_profile BEFORE UPDATE ON public.tm_tutor_profiles FOR EACH ROW EXECUTE FUNCTION tm_private.tm_preserve_shared_content();
DROP TRIGGER IF EXISTS tm_preserve_shared_post ON public.tm_tutor_statuses;
CREATE TRIGGER tm_preserve_shared_post BEFORE UPDATE ON public.tm_tutor_statuses FOR EACH ROW EXECUTE FUNCTION tm_private.tm_preserve_shared_content();
CREATE OR REPLACE FUNCTION tm_private.tm_save_shared_profile(p_body jsonb,p_publish boolean,p_consent boolean) RETURNS public.tm_tutor_profiles LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result public.tm_tutor_profiles; previous public.tm_tutor_profiles; message text;
BEGIN
 PERFORM tm_private.tm_assert_verified();
 SELECT * INTO previous FROM public.tm_tutor_profiles WHERE user_id=auth.uid() FOR UPDATE;
 IF previous.feed_visible AND previous.status!='rejected' AND NOT p_publish THEN p_publish:=true;p_consent:=true;END IF;
 IF p_publish AND p_consent IS NOT TRUE THEN RAISE EXCEPTION 'Confirm that your teaching details can appear publicly.'; END IF;
 IF p_publish AND (SELECT r.status FROM public.tm_profile_reviews r JOIN public.tm_tutor_profiles p ON p.id=r.profile_id WHERE p.user_id=auth.uid() ORDER BY r.created_at DESC,r.id DESC LIMIT 1)='rejected' THEN RAISE EXCEPTION 'Your profile was returned by an administrator. Save it for review before sharing again.'; END IF;
 result:=tm_private.tm_save_tutor(p_body,p_publish);
 IF NOT p_publish AND (SELECT r.status FROM public.tm_profile_reviews r WHERE r.profile_id=result.id ORDER BY r.created_at DESC,r.id DESC LIMIT 1)='rejected' THEN UPDATE public.tm_tutor_profiles SET status='pending' WHERE id=result.id; END IF;
 UPDATE public.tm_tutor_profiles SET feed_visible=feed_visible OR p_publish WHERE id=result.id RETURNING * INTO result;
 IF p_publish THEN
  message:=left(coalesce(nullif(trim(p_body->>'aboutEn'),''),nullif(trim(p_body->>'aboutBn'),''),'Available for tuition')||' · '||array_to_string(result.subjects,', ')||' · '||result.district,1200);
  INSERT INTO public.tm_tutor_statuses(user_id,profile_id,body,kind) VALUES(auth.uid(),result.id,message,'identity')
  ON CONFLICT(profile_id) WHERE kind='identity' DO UPDATE SET body=excluded.body,consent_at=now();
 END IF;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION tm_private.tm_hide_feed_profile() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN RAISE EXCEPTION 'Only administrators can remove published profiles.' USING ERRCODE='42501'; END $$;
CREATE OR REPLACE FUNCTION tm_private.tm_set_status_visibility(p_id uuid,p_visible boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM tm_private.tm_assert_verified();
 IF public.tm_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Administrator permission required.' USING ERRCODE='42501'; END IF;
 IF p_visible IS NULL THEN RAISE EXCEPTION 'Choose a visibility.'; END IF;
 UPDATE public.tm_tutor_statuses SET withdrawn_at=CASE WHEN p_visible THEN NULL ELSE now() END WHERE id=p_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Post not found.'; END IF;
 INSERT INTO public.tm_audit_log(actor_id,action,resource_id) VALUES(auth.uid(),CASE WHEN p_visible THEN 'post_restored' ELSE 'post_removed' END,p_id);
END $$;
CREATE OR REPLACE FUNCTION tm_private.tm_react_post(p_post uuid,p_reacted boolean) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE owner_id uuid; result bigint;
BEGIN
 PERFORM tm_private.tm_assert_verified();
 IF auth.uid() IS NULL OR p_reacted IS NULL THEN RAISE EXCEPTION 'Sign in to like a post.' USING ERRCODE='42501'; END IF;
 SELECT p.user_id INTO owner_id FROM public.tm_tutor_statuses s JOIN public.tm_tutor_profiles p ON p.id=s.profile_id WHERE s.id=p_post AND s.withdrawn_at IS NULL AND p.feed_visible AND p.status IN ('pending','approved');
 IF owner_id IS NULL THEN RAISE EXCEPTION 'This post is no longer available.'; END IF;
 IF p_reacted THEN INSERT INTO tm_private.tm_feed_reactions(post_id,user_id) VALUES(p_post,auth.uid()) ON CONFLICT DO NOTHING;
 ELSE DELETE FROM tm_private.tm_feed_reactions WHERE post_id=p_post AND user_id=auth.uid(); END IF;
 SELECT count(*) INTO result FROM tm_private.tm_feed_reactions WHERE post_id=p_post;RETURN result;
END $$;
CREATE OR REPLACE FUNCTION tm_private.tm_admin_posts(p_before timestamptz DEFAULT NULL,p_before_id uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM tm_private.tm_assert_verified();
 IF public.tm_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Administrator permission required.' USING ERRCODE='42501'; END IF;
 RETURN (SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.created_at DESC,s.id DESC),'[]'::jsonb) FROM
  (SELECT st.id,st.body,st.created_at,st.withdrawn_at,p.name,p.id AS profile_id FROM public.tm_tutor_statuses st JOIN public.tm_tutor_profiles p ON p.id=st.profile_id WHERE p_before IS NULL OR (st.created_at,st.id)<(p_before,p_before_id) ORDER BY st.created_at DESC,st.id DESC LIMIT 50) s);
END $$;
CREATE OR REPLACE FUNCTION public.tm_admin_posts(p_before timestamptz DEFAULT NULL,p_before_id uuid DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_admin_posts(p_before,p_before_id) $$;
REVOKE ALL ON FUNCTION public.tm_admin_posts(timestamptz,uuid),tm_private.tm_admin_posts(timestamptz,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_admin_posts(timestamptz,uuid),tm_private.tm_admin_posts(timestamptz,uuid) TO authenticated;
-- Keep visibility changes routed through the permission-checked RPC; clients cannot delete posts.
REVOKE INSERT,UPDATE,DELETE ON public.tm_tutor_statuses,public.tm_tutor_profiles FROM anon,authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
