-- Independent teaching posts, private drafts, public tutor documents and student shortlist.
BEGIN;
ALTER TABLE public.tm_tutor_statuses ADD COLUMN IF NOT EXISTS details jsonb;
CREATE TABLE IF NOT EXISTS tm_private.tm_teaching_drafts(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid NOT NULL REFERENCES public.tm_accounts(id) ON DELETE CASCADE,
 details jsonb NOT NULL CHECK(jsonb_typeof(details)='object' AND octet_length(details::text)<=40000),
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS tm_teaching_draft_owner ON tm_private.tm_teaching_drafts(user_id);
ALTER TABLE tm_private.tm_teaching_drafts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON tm_private.tm_teaching_drafts FROM PUBLIC,anon,authenticated;
GRANT ALL ON tm_private.tm_teaching_drafts TO service_role;
UPDATE public.tm_tutor_statuses s SET details=to_jsonb(p)-'user_id' FROM public.tm_tutor_profiles p WHERE p.id=s.profile_id AND s.kind='identity' AND s.details IS NULL;
CREATE OR REPLACE FUNCTION tm_private.tm_teaching_quota() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE used integer; q jsonb;
BEGIN
 PERFORM tm_private.tm_assert_verified();
 IF public.tm_role() IS DISTINCT FROM 'tutor' THEN RAISE EXCEPTION 'Tutor account required.' USING ERRCODE='42501';END IF;
 IF to_regprocedure('public.tm_post_quota()') IS NOT NULL THEN EXECUTE 'SELECT public.tm_post_quota()' INTO q;RETURN q;END IF;
 SELECT count(*) INTO used FROM public.tm_tutor_statuses WHERE user_id=auth.uid();
 RETURN jsonb_build_object('plan','free','limit',2,'used',used,'remaining',greatest(0,2-used),'canPost',used<2);
END $$;
CREATE OR REPLACE FUNCTION tm_private.tm_enforce_post_quota() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE q jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RETURN NEW;END IF;
 IF NEW.user_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Post ownership mismatch.' USING ERRCODE='42501';END IF;
 IF NEW.kind='identity' AND EXISTS(SELECT 1 FROM public.tm_tutor_statuses WHERE profile_id=NEW.profile_id AND kind='identity') THEN RETURN NEW;END IF;
 PERFORM 1 FROM public.tm_tutor_profiles WHERE id=NEW.profile_id FOR KEY SHARE;
 PERFORM pg_advisory_xact_lock(hashtextextended('tm-post-quota:'||NEW.user_id::text,0));
 q:=tm_private.tm_teaching_quota();
 IF (q->>'canPost')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'Your posting allowance is used. View plans to publish more.';END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION tm_private.tm_enforce_post_quota() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS tm_enforce_post_quota ON public.tm_tutor_statuses;
CREATE TRIGGER tm_enforce_post_quota BEFORE INSERT ON public.tm_tutor_statuses FOR EACH ROW EXECUTE FUNCTION tm_private.tm_enforce_post_quota();
CREATE OR REPLACE FUNCTION tm_private.tm_workspace_posts() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
 PERFORM tm_private.tm_assert_verified();
 IF public.tm_role() IS DISTINCT FROM 'tutor' THEN RAISE EXCEPTION 'Tutor account required.' USING ERRCODE='42501';END IF;
 result:=tm_private.tm_my_post_analytics();
 RETURN result||jsonb_build_object('quota',tm_private.tm_teaching_quota(),'posts',coalesce((SELECT jsonb_agg(jsonb_build_object('id',s.id,'body',s.body,'kind',s.kind,'details',s.details,'created_at',s.created_at,'withdrawn_at',s.withdrawn_at,'views',(SELECT count(*) FROM tm_private.tm_feed_views v WHERE v.post_id=s.id),'reactions',(SELECT count(*) FROM tm_private.tm_feed_reactions r WHERE r.post_id=s.id)) ORDER BY s.created_at DESC,s.id DESC) FROM public.tm_tutor_statuses s WHERE s.user_id=auth.uid()),'[]'::jsonb),'drafts',coalesce((SELECT jsonb_agg(to_jsonb(d)-'user_id' ORDER BY d.updated_at DESC) FROM tm_private.tm_teaching_drafts d WHERE d.user_id=auth.uid()),'[]'::jsonb));
END $$;
CREATE OR REPLACE FUNCTION tm_private.tm_save_teaching_post(p_id uuid,p_body jsonb,p_publish boolean,p_consent boolean) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.tm_tutor_profiles; existing public.tm_tutor_statuses; draft tm_private.tm_teaching_drafts; target uuid:=coalesce(p_id,gen_random_uuid()); q jsonb; message text; snapshot jsonb;
BEGIN
 PERFORM tm_private.tm_assert_verified();
 IF public.tm_role() IS DISTINCT FROM 'tutor' THEN RAISE EXCEPTION 'Tutor account required.' USING ERRCODE='42501';END IF;
 PERFORM 1 FROM public.tm_tutor_profiles WHERE user_id=auth.uid() FOR UPDATE;
 PERFORM pg_advisory_xact_lock(hashtextextended('tm-post-quota:'||auth.uid()::text,0));
 IF jsonb_typeof(p_body) IS DISTINCT FROM 'object' OR octet_length(p_body::text)>40000 THEN RAISE EXCEPTION 'Post details are too large.';END IF;
 IF NOT public.tm_photo_owned(nullif(p_body->>'photo_path','')) THEN RAISE EXCEPTION 'Choose your own photo.' USING ERRCODE='42501'; END IF;
 IF p_id IS NOT NULL THEN
  SELECT * INTO existing FROM public.tm_tutor_statuses WHERE id=p_id;
  SELECT * INTO draft FROM tm_private.tm_teaching_drafts WHERE id=p_id;
  IF (existing.id IS NULL AND draft.id IS NULL) OR (existing.id IS NOT NULL AND existing.user_id!=auth.uid()) OR (draft.id IS NOT NULL AND draft.user_id!=auth.uid()) THEN RAISE EXCEPTION 'Post not found.' USING ERRCODE='42501';END IF;
  IF existing.withdrawn_at IS NOT NULL THEN RAISE EXCEPTION 'This post was removed by an administrator.';END IF;
 END IF;
 IF NOT p_publish THEN
  IF existing.id IS NOT NULL THEN RAISE EXCEPTION 'A published post cannot become a private draft.';END IF;
  IF draft.id IS NULL AND (SELECT count(*) FROM tm_private.tm_teaching_drafts WHERE user_id=auth.uid())>=20 THEN RAISE EXCEPTION 'You can keep up to 20 private drafts.'; END IF;
  INSERT INTO tm_private.tm_teaching_drafts(id,user_id,details) VALUES(target,auth.uid(),p_body-'photo'-'consent') ON CONFLICT(id) DO UPDATE SET details=excluded.details,updated_at=now();
  RETURN jsonb_build_object('id',target,'draft',true);
 END IF;
 IF p_consent IS NOT TRUE THEN RAISE EXCEPTION 'Confirm public sharing before publishing.';END IF;
 IF existing.id IS NULL THEN q:=tm_private.tm_teaching_quota();IF NOT (q->>'canPost')::boolean THEN RAISE EXCEPTION 'Your posting allowance is used. View plans to publish more.';END IF;END IF;
 IF (SELECT r.status FROM public.tm_profile_reviews r JOIN public.tm_tutor_profiles t ON t.id=r.profile_id WHERE t.user_id=auth.uid() ORDER BY r.created_at DESC,r.id DESC LIMIT 1)='rejected' THEN RAISE EXCEPTION 'Resolve the administrator feedback before publishing.';END IF;
 p:=tm_private.tm_save_tutor(p_body,true);
 UPDATE public.tm_tutor_profiles SET feed_visible=true WHERE id=p.id RETURNING * INTO p;
 snapshot:=to_jsonb(p)-'user_id';
 message:=left(coalesce(nullif(trim(p_body->>'aboutEn'),''),nullif(trim(p_body->>'aboutBn'),''),'Available for tuition'),1200);
 IF existing.id IS NOT NULL THEN UPDATE public.tm_tutor_statuses SET details=snapshot,body=message,consent_at=now() WHERE id=target;
 ELSE INSERT INTO public.tm_tutor_statuses(id,user_id,profile_id,body,kind,details) VALUES(target,auth.uid(),p.id,message,'update',snapshot);END IF;
 DELETE FROM tm_private.tm_teaching_drafts WHERE id=target AND user_id=auth.uid();
 RETURN jsonb_build_object('id',target,'draft',false);
END $$;
CREATE OR REPLACE FUNCTION public.tm_teaching_quota() RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_teaching_quota() $$;
CREATE OR REPLACE FUNCTION public.tm_workspace_posts() RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_workspace_posts() $$;
CREATE OR REPLACE FUNCTION public.tm_save_teaching_post(p_id uuid,p_body jsonb,p_publish boolean,p_consent boolean DEFAULT false) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_save_teaching_post(p_id,p_body,p_publish,p_consent) $$;
REVOKE ALL ON FUNCTION public.tm_teaching_quota(),tm_private.tm_teaching_quota(),public.tm_workspace_posts(),tm_private.tm_workspace_posts(),public.tm_save_teaching_post(uuid,jsonb,boolean,boolean),tm_private.tm_save_teaching_post(uuid,jsonb,boolean,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_teaching_quota(),tm_private.tm_teaching_quota(),public.tm_workspace_posts(),tm_private.tm_workspace_posts(),public.tm_save_teaching_post(uuid,jsonb,boolean,boolean),tm_private.tm_save_teaching_post(uuid,jsonb,boolean,boolean) TO authenticated;

CREATE OR REPLACE FUNCTION tm_private.tm_browse_teaching_posts(p_filters jsonb DEFAULT '{}',p_sort text DEFAULT 'recommended',p_page integer DEFAULT 1) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE items jsonb; total bigint; budget integer:=100000; page integer:=greatest(1,least(coalesce(p_page,1),10000));
BEGIN
 IF length(coalesce(p_filters->>'q',''))>200 THEN RAISE EXCEPTION 'Use a shorter search.';END IF;
 IF coalesce(p_filters->>'budget','') ~ '^[0-9]{1,6}$' THEN budget:=(p_filters->>'budget')::integer;END IF;
 -- Filter against each post's snapshot, while current moderation always controls visibility.
 WITH candidates AS (
  SELECT s.id AS post_id,s.kind AS post_kind,s.body AS post_body,s.created_at AS posted_at,p.user_id AS owner_id,e.* FROM public.tm_tutor_statuses s JOIN public.tm_tutor_profiles p ON p.id=s.profile_id CROSS JOIN LATERAL jsonb_populate_record(NULL::public.tm_tutor_profiles,to_jsonb(p)||coalesce(s.details,'{}')) e
  WHERE s.withdrawn_at IS NULL AND (p.status='approved' OR (p.feed_visible AND p.status='pending'))
 ), matching AS (
  SELECT c FROM candidates c WHERE (coalesce(p_filters->>'district','')='' OR c.district=p_filters->>'district')
  AND (NOT p_filters ? 'districts' OR c.district IN (SELECT jsonb_array_elements_text(p_filters->'districts')))
  AND (coalesce(p_filters->>'subject','')='' OR p_filters->>'subject'=ANY(c.subjects) OR 'All subjects'=ANY(c.subjects))
  AND (coalesce(p_filters->>'className','')='' OR p_filters->>'className'=ANY(c.classes))
  AND c.fee<=budget AND (coalesce(p_filters->>'mode','')='' OR p_filters->>'mode'=ANY(c.modes))
  AND (coalesce(p_filters->>'medium','')='' OR c.medium=p_filters->>'medium' OR c.medium='Bangla & English')
  AND (coalesce(p_filters->>'available','false')!='true' OR c.available)
  AND (coalesce(p_filters->>'q','')='' OR position(lower(p_filters->>'q') in lower(concat_ws(' ',c.name,c.university,c.district,c.areas,array_to_string(c.subjects,' '),c.post_body)))>0)
 ), chosen AS (SELECT (c).* FROM matching ORDER BY CASE WHEN p_sort='low' THEN (c).fee END ASC,CASE WHEN p_sort='high' THEN (c).fee END DESC,(c).posted_at DESC,(c).post_id DESC LIMIT 6 OFFSET (page-1)*6)
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',s.id,'kind',CASE WHEN s.details IS NOT NULL THEN 'identity' ELSE s.kind END,'body',s.body,'created_at',s.created_at,'profile',(to_jsonb(p)||coalesce(s.details,'{}')||jsonb_build_object('id',p.id,'status',p.status,'feed_visible',p.feed_visible))-'user_id','owner',coalesce(p.user_id=auth.uid(),false),'reactions',(SELECT count(*) FROM tm_private.tm_feed_reactions r WHERE r.post_id=s.id),'reacted',EXISTS(SELECT 1 FROM tm_private.tm_feed_reactions r WHERE r.post_id=s.id AND r.user_id=auth.uid())) ORDER BY CASE WHEN p_sort='low' THEN c.fee END ASC,CASE WHEN p_sort='high' THEN c.fee END DESC,s.created_at DESC,s.id DESC),'[]'::jsonb),(SELECT count(*) FROM matching) INTO items,total FROM chosen c JOIN public.tm_tutor_statuses s ON s.id=c.post_id JOIN public.tm_tutor_profiles p ON p.id=s.profile_id;
 RETURN jsonb_build_object('items',items,'total',total,'page',page,'pageSize',6);
END $$;
CREATE OR REPLACE FUNCTION public.tm_browse_teaching_posts(p_filters jsonb DEFAULT '{}',p_sort text DEFAULT 'recommended',p_page integer DEFAULT 1) RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_browse_teaching_posts(p_filters,p_sort,p_page) $$;
REVOKE ALL ON FUNCTION public.tm_browse_teaching_posts(jsonb,text,integer),tm_private.tm_browse_teaching_posts(jsonb,text,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_browse_teaching_posts(jsonb,text,integer),tm_private.tm_browse_teaching_posts(jsonb,text,integer) TO anon,authenticated;

CREATE TABLE IF NOT EXISTS public.tm_tutor_documents(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid NOT NULL REFERENCES public.tm_accounts(id) ON DELETE CASCADE,
 path text NOT NULL UNIQUE,title text NOT NULL CHECK(char_length(title) BETWEEN 1 AND 100),
 kind text NOT NULL CHECK(kind IN ('cv','certificate')),size_bytes integer NOT NULL CHECK(size_bytes BETWEEN 1 AND 5242880),
 shared boolean NOT NULL DEFAULT false,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS tm_document_owner ON public.tm_tutor_documents(user_id);
ALTER TABLE public.tm_tutor_documents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tm_tutor_documents FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.tm_tutor_documents TO anon,authenticated;
GRANT ALL ON public.tm_tutor_documents TO service_role;
DROP POLICY IF EXISTS tm_document_read ON public.tm_tutor_documents;
CREATE POLICY tm_document_read ON public.tm_tutor_documents FOR SELECT TO anon,authenticated USING((user_id=(SELECT auth.uid()) AND (SELECT public.tm_auth_session_ready())) OR (shared AND EXISTS(SELECT 1 FROM public.tm_tutor_profiles p WHERE p.user_id=tm_tutor_documents.user_id AND (p.status='approved' OR (p.feed_visible AND p.status='pending')))));
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types) VALUES('tm-tutor-documents','tm-tutor-documents',false,5242880,ARRAY['application/pdf']) ON CONFLICT(id) DO UPDATE SET public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
DROP POLICY IF EXISTS tm_document_upload ON storage.objects;
CREATE POLICY tm_document_upload ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='tm-tutor-documents' AND split_part(name,'/',1)=(SELECT auth.uid())::text AND (SELECT public.tm_role())='tutor' AND (SELECT public.tm_auth_session_ready()));
DROP POLICY IF EXISTS tm_document_download ON storage.objects;
CREATE POLICY tm_document_download ON storage.objects FOR SELECT TO anon,authenticated USING(bucket_id='tm-tutor-documents' AND ((split_part(name,'/',1)=(SELECT auth.uid())::text AND (SELECT public.tm_auth_session_ready())) OR EXISTS(SELECT 1 FROM public.tm_tutor_documents d WHERE d.path=storage.objects.name AND d.shared)));
DROP POLICY IF EXISTS tm_document_delete_file ON storage.objects;
CREATE POLICY tm_document_delete_file ON storage.objects FOR DELETE TO authenticated USING(bucket_id='tm-tutor-documents' AND split_part(name,'/',1)=(SELECT auth.uid())::text AND (SELECT public.tm_auth_session_ready()) AND NOT EXISTS(SELECT 1 FROM public.tm_tutor_documents d WHERE d.path=storage.objects.name));
CREATE OR REPLACE FUNCTION tm_private.tm_document_action(p_action text,p_body jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE doc public.tm_tutor_documents; key text:=p_body->>'path';
BEGIN
 PERFORM tm_private.tm_assert_verified();
 IF public.tm_role() IS DISTINCT FROM 'tutor' THEN RAISE EXCEPTION 'Tutor account required.' USING ERRCODE='42501';END IF;
 IF p_action='add' THEN
  PERFORM pg_advisory_xact_lock(hashtextextended(auth.uid()::text,902));
  IF (SELECT count(*) FROM public.tm_tutor_documents WHERE user_id=auth.uid())>=10 THEN RAISE EXCEPTION 'You can keep up to 10 PDF documents.';END IF;
  IF split_part(key,'/',1) IS DISTINCT FROM auth.uid()::text OR NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='tm-tutor-documents' AND name=key) THEN RAISE EXCEPTION 'Upload your own PDF first.';END IF;
  INSERT INTO public.tm_tutor_documents(user_id,path,title,kind,size_bytes,shared) VALUES(auth.uid(),key,trim(p_body->>'title'),p_body->>'kind',(p_body->>'size')::integer,coalesce((p_body->>'shared')::boolean,false)) RETURNING * INTO doc;
 ELSIF p_action IN ('remove','share') THEN
  SELECT * INTO doc FROM public.tm_tutor_documents WHERE id=(p_body->>'id')::uuid AND user_id=auth.uid() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Document not found.' USING ERRCODE='42501';END IF;
  IF p_action='remove' THEN DELETE FROM public.tm_tutor_documents WHERE id=doc.id;
  ELSE UPDATE public.tm_tutor_documents SET shared=(p_body->>'shared')::boolean WHERE id=doc.id RETURNING * INTO doc;END IF;
 ELSE RAISE EXCEPTION 'Invalid document action.';END IF;
 RETURN to_jsonb(doc);
END $$;
CREATE OR REPLACE FUNCTION public.tm_document_action(p_action text,p_body jsonb) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_document_action(p_action,p_body) $$;
REVOKE ALL ON FUNCTION public.tm_document_action(text,jsonb),tm_private.tm_document_action(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_document_action(text,jsonb),tm_private.tm_document_action(text,jsonb) TO authenticated;
CREATE OR REPLACE FUNCTION tm_private.tm_public_identity(p_profile uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('name',a.name,'photo_path',coalesce(a.photo_path,p.photo_path),'district',coalesce(a.district,p.district),'university',coalesce(nullif(a.tutor_identity->>'university',''),p.university),'education',coalesce(nullif(a.tutor_identity->>'education',''),p.education),'aboutEn',coalesce(nullif(a.tutor_identity->>'introduction',''),p.about_en),'aboutBn',coalesce(nullif(a.tutor_identity->>'introductionBn',''),p.about_bn)) FROM public.tm_tutor_profiles p JOIN public.tm_accounts a ON a.id=p.user_id WHERE p.id=p_profile AND (p.status='approved' OR (p.feed_visible AND p.status='pending'))
$$;
CREATE OR REPLACE FUNCTION public.tm_public_identity(p_profile uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_public_identity(p_profile) $$;
REVOKE ALL ON FUNCTION public.tm_public_identity(uuid),tm_private.tm_public_identity(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_public_identity(uuid),tm_private.tm_public_identity(uuid) TO anon,authenticated;
-- Account rows remain private under RLS; use a safe helper for public photo ownership.
CREATE OR REPLACE FUNCTION tm_private.tm_shared_identity_photo(p_path text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT EXISTS(SELECT 1 FROM public.tm_accounts a JOIN public.tm_tutor_profiles p ON p.user_id=a.id WHERE a.photo_path=p_path AND (p.status='approved' OR (p.feed_visible AND p.status='pending'))) OR EXISTS(SELECT 1 FROM public.tm_tutor_statuses s JOIN public.tm_tutor_profiles p ON p.id=s.profile_id WHERE s.details->>'photo_path'=p_path AND s.withdrawn_at IS NULL AND (p.status='approved' OR (p.feed_visible AND p.status='pending'))) $$;
REVOKE ALL ON FUNCTION tm_private.tm_shared_identity_photo(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION tm_private.tm_shared_identity_photo(text) TO anon,authenticated;
DROP POLICY IF EXISTS tm_public_identity_photo ON storage.objects;
CREATE POLICY tm_public_identity_photo ON storage.objects FOR SELECT TO anon,authenticated USING(bucket_id='tm-profile-photos' AND tm_private.tm_shared_identity_photo(name));
DROP POLICY IF EXISTS tm_save_insert ON public.tm_saved_tutors;
CREATE POLICY tm_save_insert ON public.tm_saved_tutors FOR INSERT TO authenticated WITH CHECK(user_id=(SELECT auth.uid()) AND (SELECT public.tm_role())='student' AND (SELECT public.tm_auth_session_ready()) AND EXISTS(SELECT 1 FROM public.tm_tutor_profiles p WHERE p.id=profile_id AND (p.status='approved' OR (p.feed_visible AND p.status='pending'))));
CREATE OR REPLACE FUNCTION tm_private.tm_list_documents(p_profile uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',d.id,'path',d.path,'title',d.title,'kind',d.kind,'size_bytes',d.size_bytes,'created_at',d.created_at) ORDER BY d.created_at DESC),'[]'::jsonb) FROM public.tm_tutor_documents d JOIN public.tm_tutor_profiles p ON p.user_id=d.user_id WHERE p.id=p_profile AND d.shared AND (p.status='approved' OR (p.feed_visible AND p.status='pending'))
$$;
CREATE OR REPLACE FUNCTION public.tm_list_documents(p_profile uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_list_documents(p_profile) $$;
REVOKE ALL ON FUNCTION public.tm_list_documents(uuid),tm_private.tm_list_documents(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_list_documents(uuid),tm_private.tm_list_documents(uuid) TO anon,authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
