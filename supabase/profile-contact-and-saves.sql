-- Exact tutor/post routes, durable student favourites, and private contact email outbox.
BEGIN;
CREATE OR REPLACE FUNCTION tm_private.tm_tutor_page(p_profile uuid,p_post uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.tm_tutor_profiles; s public.tm_tutor_statuses; result jsonb; identity jsonb;
BEGIN
 SELECT * INTO p FROM public.tm_tutor_profiles WHERE id=p_profile AND (status='approved' OR (feed_visible AND status='pending'));
 IF NOT FOUND THEN RETURN NULL;END IF;
 result:=to_jsonb(p)-'user_id';
 IF p_post IS NOT NULL THEN
  SELECT * INTO s FROM public.tm_tutor_statuses WHERE id=p_post AND profile_id=p.id AND withdrawn_at IS NULL;
  IF NOT FOUND THEN RETURN NULL;END IF;
  result:=result||coalesce(s.details,'{}'::jsonb);
 ELSE
  identity:=tm_private.tm_public_identity(p.id);
  IF identity IS NOT NULL THEN result:=result||identity||jsonb_build_object('about_en',identity->>'aboutEn','about_bn',identity->>'aboutBn');END IF;
 END IF;
 -- A snapshot must never change the route or owner used for contact and saved records.
 RETURN (result-'user_id')||jsonb_build_object('id',p.id,'status',p.status,'feed_visible',p.feed_visible,'postId',p_post);
END $$;
CREATE OR REPLACE FUNCTION public.tm_tutor_page(p_profile uuid,p_post uuid DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_tutor_page(p_profile,p_post) $$;
REVOKE ALL ON FUNCTION public.tm_tutor_page(uuid,uuid),tm_private.tm_tutor_page(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_tutor_page(uuid,uuid),tm_private.tm_tutor_page(uuid,uuid) TO anon,authenticated;

ALTER TABLE public.tm_saved_tutors ADD COLUMN IF NOT EXISTS snapshot jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.tm_saved_tutors ADD COLUMN IF NOT EXISTS post_id uuid;
-- Retain the owner's private saved entry if a tutor/post is later removed.
DO $$ DECLARE c record;BEGIN
 FOR c IN SELECT conname FROM pg_constraint WHERE conrelid='public.tm_saved_tutors'::regclass AND confrelid='public.tm_tutor_profiles'::regclass AND contype='f' LOOP EXECUTE format('ALTER TABLE public.tm_saved_tutors DROP CONSTRAINT %I',c.conname);END LOOP;
END $$;
UPDATE public.tm_saved_tutors f SET snapshot=coalesce(tm_private.tm_tutor_page(f.profile_id,f.post_id),jsonb_build_object('id',f.profile_id,'name','Saved tutor','subjects','[]'::jsonb,'classes','[]'::jsonb,'modes','[]'::jsonb,'days','[]'::jsonb,'areas','','fee',0)) WHERE snapshot='{}'::jsonb;
CREATE OR REPLACE FUNCTION tm_private.tm_capture_favourite() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NOT NULL AND NEW.user_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Saved tutor ownership mismatch.' USING ERRCODE='42501';END IF;
 NEW.snapshot:=tm_private.tm_tutor_page(NEW.profile_id,NEW.post_id);
 IF NEW.snapshot IS NULL THEN RAISE EXCEPTION 'This tutor or post is no longer publicly available.';END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION tm_private.tm_capture_favourite() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS tm_capture_favourite ON public.tm_saved_tutors;
CREATE TRIGGER tm_capture_favourite BEFORE INSERT ON public.tm_saved_tutors FOR EACH ROW EXECUTE FUNCTION tm_private.tm_capture_favourite();
CREATE OR REPLACE FUNCTION tm_private.tm_save_favourite(p_profile uuid,p_post uuid DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM tm_private.tm_assert_verified();IF public.tm_role() IS DISTINCT FROM 'student' THEN RAISE EXCEPTION 'Student account required.' USING ERRCODE='42501';END IF;
 INSERT INTO public.tm_saved_tutors(user_id,profile_id,post_id) VALUES(auth.uid(),p_profile,p_post) ON CONFLICT(user_id,profile_id) DO NOTHING;
END $$;
CREATE OR REPLACE FUNCTION tm_private.tm_my_saved_tutors() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM tm_private.tm_assert_verified();IF public.tm_role() IS DISTINCT FROM 'student' THEN RAISE EXCEPTION 'Student account required.' USING ERRCODE='42501';END IF;
 RETURN coalesce((SELECT jsonb_agg(f.snapshot||jsonb_build_object('id',f.profile_id,'postId',f.post_id,'unavailable',NOT EXISTS(SELECT 1 FROM public.tm_tutor_profiles p WHERE p.id=f.profile_id AND (p.status='approved' OR (p.feed_visible AND p.status='pending')) AND (f.post_id IS NULL OR EXISTS(SELECT 1 FROM public.tm_tutor_statuses s WHERE s.id=f.post_id AND s.profile_id=p.id AND s.withdrawn_at IS NULL)))) ORDER BY f.created_at DESC) FROM public.tm_saved_tutors f WHERE f.user_id=auth.uid()),'[]'::jsonb);
END $$;
CREATE OR REPLACE FUNCTION public.tm_save_favourite(p_profile uuid,p_post uuid DEFAULT NULL) RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_save_favourite(p_profile,p_post) $$;
CREATE OR REPLACE FUNCTION public.tm_my_saved_tutors() RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_my_saved_tutors() $$;
REVOKE ALL ON FUNCTION public.tm_save_favourite(uuid,uuid),tm_private.tm_save_favourite(uuid,uuid),public.tm_my_saved_tutors(),tm_private.tm_my_saved_tutors() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_save_favourite(uuid,uuid),tm_private.tm_save_favourite(uuid,uuid),public.tm_my_saved_tutors(),tm_private.tm_my_saved_tutors() TO authenticated;

ALTER TABLE public.tm_contact_requests ADD COLUMN IF NOT EXISTS student_email text;
ALTER TABLE public.tm_contact_requests ADD COLUMN IF NOT EXISTS post_id uuid;
CREATE TABLE IF NOT EXISTS tm_private.tm_contact_email_outbox(
 request_id uuid PRIMARY KEY REFERENCES public.tm_contact_requests(id) ON DELETE CASCADE,student_id uuid NOT NULL REFERENCES public.tm_accounts(id) ON DELETE CASCADE,tutor_id uuid NOT NULL REFERENCES public.tm_accounts(id) ON DELETE CASCADE,
 to_email text,reply_to_email text NOT NULL,from_email text,subject text NOT NULL,text_body text NOT NULL,
 status text NOT NULL DEFAULT 'queued' CHECK(status IN ('queued','sending','sent','failed','unknown')),
 attempts integer NOT NULL DEFAULT 0,claim_id uuid,claimed_at timestamptz,sent_at timestamptz,provider_message_id text,last_error text,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS tm_contact_outbox_student ON tm_private.tm_contact_email_outbox(student_id);
CREATE INDEX IF NOT EXISTS tm_contact_outbox_tutor ON tm_private.tm_contact_email_outbox(tutor_id);
ALTER TABLE tm_private.tm_contact_email_outbox ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON tm_private.tm_contact_email_outbox FROM PUBLIC,anon,authenticated;
GRANT ALL ON tm_private.tm_contact_email_outbox TO service_role;
CREATE OR REPLACE FUNCTION tm_private.tm_queue_contact_email() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE student_address text;tutor_address text;owner_id uuid;
BEGIN
 SELECT email INTO student_address FROM auth.users WHERE id=NEW.student_id;
 SELECT p.user_id,u.email INTO owner_id,tutor_address FROM public.tm_tutor_profiles p JOIN auth.users u ON u.id=p.user_id WHERE p.id=NEW.profile_id;
 IF nullif(student_address,'') IS NULL OR owner_id IS NULL THEN RAISE EXCEPTION 'Registered contact email unavailable.';END IF;
 UPDATE public.tm_contact_requests SET student_email=student_address WHERE id=NEW.id;
 INSERT INTO tm_private.tm_contact_email_outbox(request_id,student_id,tutor_id,to_email,reply_to_email,subject,text_body)
 VALUES(NEW.id,NEW.student_id,owner_id,tutor_address,student_address,'New tuition request · Tutormela',concat('A student or guardian sent you a tuition request on Tutormela.',E'\n\n','Student: ',NEW.student_name,E'\n','Reply email: ',student_address,E'\n','Class: ',NEW.class_name,E'\n','Subject: ',NEW.subject,E'\n','Teaching mode: ',NEW.mode,E'\n\n',NEW.message,E'\n\n','Additional contact: ',NEW.contact,E'\n\n','Reply to this email to contact the student directly. You can also manage this request in your Tutormela dashboard.')) ON CONFLICT(request_id) DO NOTHING;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION tm_private.tm_queue_contact_email() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS tm_queue_contact_email ON public.tm_contact_requests;
CREATE TRIGGER tm_queue_contact_email AFTER INSERT ON public.tm_contact_requests FOR EACH ROW EXECUTE FUNCTION tm_private.tm_queue_contact_email();
CREATE OR REPLACE FUNCTION tm_private.tm_send_request(p_body jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE page jsonb;email_address text;target uuid:=(p_body->>'profileId')::uuid;post uuid:=nullif(p_body->>'postId','')::uuid;result uuid;
BEGIN
 PERFORM tm_private.tm_assert_verified();IF public.tm_role() IS DISTINCT FROM 'student' THEN RAISE EXCEPTION 'Student or guardian account required.' USING ERRCODE='42501';END IF;
 IF coalesce((p_body->>'consent')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'Confirm consent to share your message and email.';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('contact:'||auth.uid()::text,0));
 IF (SELECT count(*) FROM public.tm_contact_requests WHERE student_id=auth.uid() AND created_at>now()-interval '1 day')>=20 THEN RAISE EXCEPTION 'You have reached today’s contact request limit.';END IF;
 page:=tm_private.tm_tutor_page(target,post);
 IF page IS NULL OR (page->>'available')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'This tutor is not currently available for requests.';END IF;
 IF NOT (page->'classes' ? (p_body->>'className') AND page->'subjects' ? (p_body->>'subject') AND page->'modes' ? (p_body->>'mode')) THEN RAISE EXCEPTION 'Choose the selected tutor’s available class, subject and mode.';END IF;
 SELECT email INTO email_address FROM auth.users WHERE id=auth.uid();
 IF nullif(email_address,'') IS NULL THEN RAISE EXCEPTION 'Your signed-in account needs a verified email.';END IF;
 INSERT INTO public.tm_contact_requests(student_id,profile_id,post_id,student_name,class_name,subject,mode,message,contact,student_email)
 VALUES(auth.uid(),target,post,trim(p_body->>'studentName'),p_body->>'className',p_body->>'subject',p_body->>'mode',trim(p_body->>'message'),coalesce(nullif(trim(p_body->>'contact'),''),email_address),email_address) RETURNING id INTO result;
 INSERT INTO public.tm_audit_log(actor_id,action,resource_id) VALUES(auth.uid(),'request_sent',result);RETURN result;
 EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'You already have a pending request with this tutor.';
END $$;
CREATE OR REPLACE FUNCTION tm_private.tm_my_requests() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM tm_private.tm_assert_verified();
 RETURN (SELECT coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('tutor_name',coalesce(nullif(s.details->>'name',''),p.name),'email_status',o.status) ORDER BY r.created_at DESC),'[]'::jsonb) FROM public.tm_contact_requests r JOIN public.tm_tutor_profiles p ON p.id=r.profile_id LEFT JOIN public.tm_tutor_statuses s ON s.id=r.post_id LEFT JOIN tm_private.tm_contact_email_outbox o ON o.request_id=r.id WHERE (public.tm_role()='student' AND r.student_id=auth.uid()) OR (public.tm_role()='tutor' AND p.user_id=auth.uid()));
END $$;
-- Service-only sender operations. Addresses and message bodies never come from the browser.
CREATE OR REPLACE FUNCTION tm_private.tm_contact_delivery(p_action text,p_request uuid,p_user uuid,p_claim uuid DEFAULT NULL,p_result jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE o tm_private.tm_contact_email_outbox;
BEGIN
 SELECT * INTO o FROM tm_private.tm_contact_email_outbox WHERE request_id=p_request AND student_id=p_user FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Contact request not found.' USING ERRCODE='42501';END IF;
 IF p_action='claim' THEN
  IF NOT EXISTS(SELECT 1 FROM public.tm_contact_requests WHERE id=p_request AND status='pending') THEN RETURN jsonb_build_object('claimed',false,'status','inactive');END IF;
  IF o.status='sending' AND o.claimed_at<now()-interval '2 minutes' THEN UPDATE tm_private.tm_contact_email_outbox SET status='unknown',last_error='delivery_confirmation_unavailable' WHERE request_id=p_request;RETURN jsonb_build_object('claimed',false,'status','unknown');END IF;
  IF o.status NOT IN ('queued','failed') OR o.attempts>=3 OR (o.claimed_at IS NOT NULL AND o.claimed_at>now()-interval '1 minute') THEN RETURN jsonb_build_object('claimed',false,'status',o.status);END IF;
  UPDATE tm_private.tm_contact_email_outbox SET claim_id=gen_random_uuid(),status='sending',claimed_at=now(),attempts=attempts+1,last_error=NULL WHERE request_id=p_request RETURNING * INTO o;
  RETURN to_jsonb(o)||jsonb_build_object('claimed',true);
 ELSIF p_action='finish' THEN
  IF o.claim_id IS DISTINCT FROM p_claim OR o.status!='sending' THEN RAISE EXCEPTION 'Delivery claim expired.';END IF;
  IF p_result->>'status' NOT IN ('sent','failed','unknown') THEN RAISE EXCEPTION 'Invalid email outcome.';END IF;
  UPDATE tm_private.tm_contact_email_outbox SET status=p_result->>'status',from_email=left(p_result->>'from',320),sent_at=CASE WHEN p_result->>'status'='sent' THEN now() END,provider_message_id=left(p_result->>'messageId',300),last_error=left(p_result->>'error',80) WHERE request_id=p_request;
  RETURN jsonb_build_object('status',p_result->>'status');
 END IF;
 RAISE EXCEPTION 'Invalid delivery action.';
END $$;
CREATE OR REPLACE FUNCTION public.tm_contact_delivery(p_action text,p_request uuid,p_user uuid,p_claim uuid DEFAULT NULL,p_result jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_contact_delivery(p_action,p_request,p_user,p_claim,p_result) $$;
REVOKE ALL ON FUNCTION public.tm_contact_delivery(text,uuid,uuid,uuid,jsonb),tm_private.tm_contact_delivery(text,uuid,uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_contact_delivery(text,uuid,uuid,uuid,jsonb),tm_private.tm_contact_delivery(text,uuid,uuid,uuid,jsonb) TO service_role;
-- Existing pending requests become retryable; migration never sends an email itself.
INSERT INTO tm_private.tm_contact_email_outbox(request_id,student_id,tutor_id,to_email,reply_to_email,subject,text_body)
SELECT r.id,r.student_id,p.user_id,t.email,u.email,'New tuition request · Tutormela',concat('A student or guardian sent you a tuition request on Tutormela.',E'\n\n','Student: ',r.student_name,E'\n','Reply email: ',u.email,E'\n','Class: ',r.class_name,E'\n','Subject: ',r.subject,E'\n','Teaching mode: ',r.mode,E'\n\n',r.message,E'\n\n','Additional contact: ',r.contact,E'\n\n','Reply to this email to contact the student directly. You can also manage this request in your Tutormela dashboard.')
FROM public.tm_contact_requests r JOIN public.tm_tutor_profiles p ON p.id=r.profile_id JOIN auth.users u ON u.id=r.student_id JOIN auth.users t ON t.id=p.user_id WHERE r.status='pending' AND nullif(u.email,'') IS NOT NULL
ON CONFLICT(request_id) DO NOTHING;
UPDATE public.tm_contact_requests r SET student_email=o.reply_to_email FROM tm_private.tm_contact_email_outbox o WHERE o.request_id=r.id AND r.student_email IS NULL;
NOTIFY pgrst,'reload schema';
COMMIT;
