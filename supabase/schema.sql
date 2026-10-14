-- Tutormela / Supabase PostgreSQL schema v1
-- Run this complete file in your project's SQL Editor as project owner.
-- Safe to rerun: it does not drop application tables or user data.
-- Passwords, email identities and sessions belong to Supabase Auth, NOT public tables.
BEGIN;
CREATE SCHEMA IF NOT EXISTS tm_private;
REVOKE ALL ON SCHEMA tm_private FROM PUBLIC,anon,authenticated;
GRANT USAGE ON SCHEMA tm_private TO anon,authenticated;

CREATE TABLE IF NOT EXISTS public.tm_catalog (
 category text NOT NULL CHECK (category IN ('districts','subjects','classes','modes','days')),
 value text NOT NULL, label_bn text, sort_order integer NOT NULL DEFAULT 0,
 PRIMARY KEY(category,value)
);
CREATE TABLE IF NOT EXISTS public.tm_accounts (
 id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
 name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 80),
 role text NOT NULL DEFAULT 'student' CHECK(role IN ('student','tutor','admin')),
 photo_path text, phone text NOT NULL DEFAULT '' CHECK(char_length(phone)<=40),
 district text, learning_goals text NOT NULL DEFAULT '' CHECK(char_length(learning_goals)<=1500),
 preferences jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(preferences)='object' AND octet_length(preferences::text)<=12000),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.tm_tutor_profiles (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid NOT NULL UNIQUE REFERENCES public.tm_accounts(id) ON DELETE CASCADE,
 name text NOT NULL DEFAULT '' CHECK(char_length(name)<=80),
 university text NOT NULL DEFAULT '' CHECK(char_length(university)<=200),
 education text NOT NULL DEFAULT '' CHECK(char_length(education)<=200),
 district text NOT NULL DEFAULT '', areas text NOT NULL DEFAULT '' CHECK(char_length(areas)<=200),
 subjects text[] NOT NULL DEFAULT '{}', classes text[] NOT NULL DEFAULT '{}', modes text[] NOT NULL DEFAULT '{}', days text[] NOT NULL DEFAULT '{}',
 fee integer NOT NULL DEFAULT 5000 CHECK(fee BETWEEN 500 AND 100000),
 experience text NOT NULL DEFAULT '' CHECK(char_length(experience)<=60),
 time text NOT NULL DEFAULT 'Evening' CHECK(time IN ('Morning','Afternoon','Evening','Flexible')),
 medium text NOT NULL DEFAULT 'Bangla & English' CHECK(medium IN ('Bangla medium','English medium','Bangla & English')),
 about_en text NOT NULL DEFAULT '' CHECK(char_length(about_en)<=3000),
 about_bn text NOT NULL DEFAULT '' CHECK(char_length(about_bn)<=3000),
 available boolean NOT NULL DEFAULT true, photo_path text,
 status text NOT NULL DEFAULT 'draft' CHECK(status IN ('draft','pending','approved','rejected')),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.tm_profile_reviews (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 profile_id uuid NOT NULL REFERENCES public.tm_tutor_profiles(id) ON DELETE CASCADE,
 reviewed_by uuid REFERENCES public.tm_accounts(id) ON DELETE SET NULL,
 status text NOT NULL CHECK(status IN ('approved','rejected')),
 reason text NOT NULL DEFAULT '' CHECK(char_length(reason)<=600 AND (status!='rejected' OR char_length(trim(reason))>0)),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.tm_saved_tutors (
 user_id uuid NOT NULL REFERENCES public.tm_accounts(id) ON DELETE CASCADE,
 profile_id uuid NOT NULL REFERENCES public.tm_tutor_profiles(id) ON DELETE CASCADE,
 created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(user_id,profile_id)
);
CREATE TABLE IF NOT EXISTS public.tm_contact_requests (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 student_id uuid NOT NULL REFERENCES public.tm_accounts(id) ON DELETE CASCADE,
 profile_id uuid NOT NULL REFERENCES public.tm_tutor_profiles(id) ON DELETE CASCADE,
 student_name text NOT NULL CHECK(char_length(trim(student_name)) BETWEEN 1 AND 80),
 class_name text NOT NULL, subject text NOT NULL, mode text NOT NULL,
 message text NOT NULL CHECK(char_length(trim(message)) BETWEEN 1 AND 1500),
 contact text NOT NULL CHECK(char_length(trim(contact)) BETWEEN 1 AND 160),
 consent_at timestamptz NOT NULL DEFAULT now(),
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','accepted','declined','cancelled')),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS tm_one_pending_request ON public.tm_contact_requests(student_id,profile_id) WHERE status='pending';
CREATE INDEX IF NOT EXISTS tm_profiles_search ON public.tm_tutor_profiles(status,district,fee);
CREATE INDEX IF NOT EXISTS tm_requests_student ON public.tm_contact_requests(student_id,created_at DESC);
CREATE INDEX IF NOT EXISTS tm_requests_tutor ON public.tm_contact_requests(profile_id,created_at DESC);
CREATE INDEX IF NOT EXISTS tm_review_history ON public.tm_profile_reviews(profile_id,created_at DESC);
CREATE TABLE IF NOT EXISTS public.tm_audit_log (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 actor_id uuid REFERENCES public.tm_accounts(id) ON DELETE SET NULL,
 action text NOT NULL, resource_id uuid, created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION tm_private.tm_role() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT role FROM public.tm_accounts WHERE id=(SELECT auth.uid())
$$;
CREATE OR REPLACE FUNCTION public.tm_role() RETURNS text LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_role() $$;
CREATE OR REPLACE FUNCTION public.tm_catalog_has(p_category text,p_value text) RETURNS boolean LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.tm_catalog WHERE category=p_category AND value=p_value)
$$;
CREATE OR REPLACE FUNCTION public.tm_valid_choices(p_category text,p_values text[]) RETURNS boolean LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT cardinality(p_values)>0 AND NOT EXISTS(SELECT 1 FROM unnest(p_values) v WHERE NOT public.tm_catalog_has(p_category,v))
$$;
CREATE OR REPLACE FUNCTION tm_private.tm_photo_owned(p_path text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT p_path IS NULL OR (split_part(p_path,'/',1)=(SELECT auth.uid())::text AND EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='tm-profile-photos' AND name=p_path))
$$;
CREATE OR REPLACE FUNCTION public.tm_photo_owned(p_path text) RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_photo_owned(p_path) $$;
CREATE OR REPLACE FUNCTION tm_private.tm_handle_new_user() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 INSERT INTO public.tm_accounts(id,name,role)
 VALUES(NEW.id,left(coalesce(nullif(trim(NEW.raw_user_meta_data->>'name'),''),split_part(NEW.email,'@',1),'Member'),80),
 CASE WHEN NEW.raw_user_meta_data->>'role'='tutor' THEN 'tutor' ELSE 'student' END) ON CONFLICT(id) DO NOTHING;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS tm_on_auth_user_created ON auth.users;
CREATE TRIGGER tm_on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION tm_private.tm_handle_new_user();
-- Backfill existing Auth users without trusting any client-supplied admin role.
INSERT INTO public.tm_accounts(id,name,role)
SELECT id,left(coalesce(nullif(trim(raw_user_meta_data->>'name'),''),split_part(email,'@',1),'Member'),80),CASE WHEN raw_user_meta_data->>'role'='tutor' THEN 'tutor' ELSE 'student' END FROM auth.users ON CONFLICT(id) DO NOTHING;

CREATE OR REPLACE FUNCTION tm_private.tm_update_account(p_body jsonb) RETURNS public.tm_accounts LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result public.tm_accounts; photo text:=nullif(p_body->>'photo_path','');
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in.' USING ERRCODE='42501'; END IF;
 IF NOT public.tm_photo_owned(photo) THEN RAISE EXCEPTION 'You can only select your own uploaded photo.' USING ERRCODE='42501'; END IF;
 IF nullif(p_body->>'district','') IS NOT NULL AND NOT public.tm_catalog_has('districts',p_body->>'district') THEN RAISE EXCEPTION 'Choose a valid district.'; END IF;
 UPDATE public.tm_accounts SET name=trim(p_body->>'name'),photo_path=photo,phone=coalesce(p_body->>'phone',''),district=nullif(p_body->>'district',''),learning_goals=coalesce(p_body->>'learning_goals',''),updated_at=now() WHERE id=auth.uid() RETURNING * INTO result;
 IF NOT FOUND THEN RAISE EXCEPTION 'Account not found.'; END IF;
 INSERT INTO public.tm_audit_log(actor_id,action,resource_id) VALUES(auth.uid(),'account_updated',auth.uid());
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.tm_update_account(p_body jsonb) RETURNS public.tm_accounts LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_update_account(p_body) $$;
CREATE OR REPLACE FUNCTION tm_private.tm_save_preferences(p_preferences jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in.' USING ERRCODE='42501'; END IF;
 UPDATE public.tm_accounts SET preferences=p_preferences,updated_at=now() WHERE id=auth.uid();
END $$;
CREATE OR REPLACE FUNCTION public.tm_save_preferences(p_preferences jsonb) RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_save_preferences(p_preferences) $$;

CREATE OR REPLACE FUNCTION tm_private.tm_save_tutor(p_body jsonb,p_submit boolean DEFAULT true) RETURNS public.tm_tutor_profiles LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result public.tm_tutor_profiles; photo text:=nullif(p_body->>'photo_path','');
 ss text[]:=ARRAY(SELECT jsonb_array_elements_text(coalesce(p_body->'subjects','[]')));
 cc text[]:=ARRAY(SELECT jsonb_array_elements_text(coalesce(p_body->'classes','[]')));
 mm text[]:=ARRAY(SELECT jsonb_array_elements_text(coalesce(p_body->'modes','[]')));
 dd text[]:=ARRAY(SELECT jsonb_array_elements_text(coalesce(p_body->'days','[]')));
BEGIN
 IF public.tm_role() IS DISTINCT FROM 'tutor' THEN RAISE EXCEPTION 'Only tutors can publish teaching profiles.' USING ERRCODE='42501'; END IF;
 IF NOT public.tm_photo_owned(photo) THEN RAISE EXCEPTION 'Select your own uploaded photo.' USING ERRCODE='42501'; END IF;
 IF p_submit AND (nullif(trim(p_body->>'name'),'') IS NULL OR nullif(trim(p_body->>'university'),'') IS NULL OR nullif(trim(p_body->>'education'),'') IS NULL OR nullif(trim(p_body->>'areas'),'') IS NULL OR nullif(trim(p_body->>'aboutEn'),'') IS NULL OR nullif(trim(p_body->>'aboutBn'),'') IS NULL OR NOT public.tm_catalog_has('districts',p_body->>'district') OR NOT public.tm_valid_choices('subjects',ss) OR NOT public.tm_valid_choices('classes',cc) OR NOT public.tm_valid_choices('modes',mm) OR NOT public.tm_valid_choices('days',dd)) THEN RAISE EXCEPTION 'Complete education, district, subjects, classes, modes, days and both introductions before submitting.'; END IF;
 INSERT INTO public.tm_tutor_profiles(user_id,name,university,education,district,areas,subjects,classes,modes,days,fee,experience,time,medium,about_en,about_bn,available,photo_path,status)
 VALUES(auth.uid(),coalesce(trim(p_body->>'name'),''),coalesce(p_body->>'university',''),coalesce(p_body->>'education',''),coalesce(p_body->>'district',''),coalesce(p_body->>'areas',''),ss,cc,mm,dd,coalesce((p_body->>'fee')::integer,5000),coalesce(p_body->>'experience',''),coalesce(p_body->>'time','Evening'),coalesce(p_body->>'medium','Bangla & English'),coalesce(p_body->>'aboutEn',''),coalesce(p_body->>'aboutBn',''),coalesce((p_body->>'available')::boolean,true),photo,CASE WHEN p_submit THEN 'pending' ELSE 'draft' END)
 ON CONFLICT(user_id) DO UPDATE SET name=excluded.name,university=excluded.university,education=excluded.education,district=excluded.district,areas=excluded.areas,subjects=excluded.subjects,classes=excluded.classes,modes=excluded.modes,days=excluded.days,fee=excluded.fee,experience=excluded.experience,time=excluded.time,medium=excluded.medium,about_en=excluded.about_en,about_bn=excluded.about_bn,available=excluded.available,photo_path=excluded.photo_path,status=excluded.status,updated_at=now() RETURNING * INTO result;
 INSERT INTO public.tm_audit_log(actor_id,action,resource_id) VALUES(auth.uid(),CASE WHEN p_submit THEN 'profile_submitted' ELSE 'profile_draft_saved' END,result.id);
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.tm_save_tutor(p_body jsonb,p_submit boolean DEFAULT true) RETURNS public.tm_tutor_profiles LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_save_tutor(p_body,p_submit) $$;
CREATE OR REPLACE FUNCTION tm_private.tm_review_tutor(p_id uuid,p_status text,p_reason text DEFAULT '') RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF public.tm_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Administrator permission required.' USING ERRCODE='42501'; END IF;
 IF p_status NOT IN ('approved','rejected') OR (p_status='rejected' AND nullif(trim(p_reason),'') IS NULL) THEN RAISE EXCEPTION 'Choose approval or provide feedback for changes.'; END IF;
 UPDATE public.tm_tutor_profiles SET status=p_status,updated_at=now() WHERE id=p_id AND status!='draft';
 IF NOT FOUND THEN RAISE EXCEPTION 'Profile not found or still a draft.'; END IF;
 INSERT INTO public.tm_profile_reviews(profile_id,reviewed_by,status,reason) VALUES(p_id,auth.uid(),p_status,coalesce(p_reason,''));
 INSERT INTO public.tm_audit_log(actor_id,action,resource_id) VALUES(auth.uid(),'profile_'||p_status,p_id);
END $$;
CREATE OR REPLACE FUNCTION public.tm_review_tutor(p_id uuid,p_status text,p_reason text DEFAULT '') RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_review_tutor(p_id,p_status,p_reason) $$;
CREATE OR REPLACE FUNCTION tm_private.tm_send_request(p_body jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE tutor public.tm_tutor_profiles; result uuid;
BEGIN
 IF public.tm_role() IS DISTINCT FROM 'student' THEN RAISE EXCEPTION 'Use a student or guardian account.' USING ERRCODE='42501'; END IF;
 IF coalesce((p_body->>'consent')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'Confirm consent to share this request with the tutor.'; END IF;
 SELECT * INTO tutor FROM public.tm_tutor_profiles WHERE id=(p_body->>'profileId')::uuid AND status='approved' AND available;
 IF NOT FOUND THEN RAISE EXCEPTION 'Tutor is not available for requests.'; END IF;
 IF NOT (p_body->>'className'=ANY(tutor.classes) AND p_body->>'subject'=ANY(tutor.subjects) AND p_body->>'mode'=ANY(tutor.modes)) THEN RAISE EXCEPTION 'Choose this tutor''s available class, subject and mode.'; END IF;
 INSERT INTO public.tm_contact_requests(student_id,profile_id,student_name,class_name,subject,mode,message,contact)
 VALUES(auth.uid(),tutor.id,trim(p_body->>'studentName'),p_body->>'className',p_body->>'subject',p_body->>'mode',trim(p_body->>'message'),trim(p_body->>'contact')) RETURNING id INTO result;
 INSERT INTO public.tm_audit_log(actor_id,action,resource_id) VALUES(auth.uid(),'request_sent',result);
 RETURN result;
EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'You already have a pending request with this tutor.';
END $$;
CREATE OR REPLACE FUNCTION public.tm_send_request(p_body jsonb) RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_send_request(p_body) $$;
CREATE OR REPLACE FUNCTION tm_private.tm_update_request(p_id uuid,p_status text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE request public.tm_contact_requests; owner uuid;
BEGIN
 SELECT * INTO request FROM public.tm_contact_requests WHERE id=p_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Request not found.'; END IF;
 SELECT user_id INTO owner FROM public.tm_tutor_profiles WHERE id=request.profile_id;
 IF NOT ((public.tm_role()='student' AND request.student_id=auth.uid() AND p_status='cancelled') OR (public.tm_role()='tutor' AND owner=auth.uid() AND p_status IN ('accepted','declined'))) THEN RAISE EXCEPTION 'You do not have permission to change this request.' USING ERRCODE='42501'; END IF;
 IF request.status!='pending' THEN RAISE EXCEPTION 'This request has already been resolved.'; END IF;
 UPDATE public.tm_contact_requests SET status=p_status,updated_at=now() WHERE id=p_id;
 INSERT INTO public.tm_audit_log(actor_id,action,resource_id) VALUES(auth.uid(),'request_'||p_status,p_id);
END $$;
CREATE OR REPLACE FUNCTION public.tm_update_request(p_id uuid,p_status text) RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_update_request(p_id,p_status) $$;
CREATE OR REPLACE FUNCTION tm_private.tm_my_requests() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('tutor_name',p.name) ORDER BY r.created_at DESC),'[]'::jsonb)
 FROM public.tm_contact_requests r JOIN public.tm_tutor_profiles p ON p.id=r.profile_id
 WHERE (public.tm_role()='student' AND r.student_id=auth.uid()) OR (public.tm_role()='tutor' AND p.user_id=auth.uid())
$$;
CREATE OR REPLACE FUNCTION public.tm_my_requests() RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_my_requests() $$;

ALTER TABLE public.tm_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tm_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tm_tutor_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tm_profile_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tm_saved_tutors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tm_contact_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tm_audit_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tm_catalog_read ON public.tm_catalog;
CREATE POLICY tm_catalog_read ON public.tm_catalog FOR SELECT TO anon,authenticated USING(true);
DROP POLICY IF EXISTS tm_account_read ON public.tm_accounts;
CREATE POLICY tm_account_read ON public.tm_accounts FOR SELECT TO authenticated USING(id=(SELECT auth.uid()));
DROP POLICY IF EXISTS tm_profile_read ON public.tm_tutor_profiles;
CREATE POLICY tm_profile_read ON public.tm_tutor_profiles FOR SELECT TO anon,authenticated USING(status='approved' OR user_id=(SELECT auth.uid()) OR (SELECT public.tm_role())='admin');
DROP POLICY IF EXISTS tm_review_read ON public.tm_profile_reviews;
CREATE POLICY tm_review_read ON public.tm_profile_reviews FOR SELECT TO authenticated USING((SELECT public.tm_role())='admin' OR EXISTS(SELECT 1 FROM public.tm_tutor_profiles p WHERE p.id=profile_id AND p.user_id=(SELECT auth.uid())));
DROP POLICY IF EXISTS tm_save_read ON public.tm_saved_tutors;
CREATE POLICY tm_save_read ON public.tm_saved_tutors FOR SELECT TO authenticated USING(user_id=(SELECT auth.uid()) AND (SELECT public.tm_role())='student');
DROP POLICY IF EXISTS tm_save_insert ON public.tm_saved_tutors;
CREATE POLICY tm_save_insert ON public.tm_saved_tutors FOR INSERT TO authenticated WITH CHECK(user_id=(SELECT auth.uid()) AND (SELECT public.tm_role())='student' AND EXISTS(SELECT 1 FROM public.tm_tutor_profiles p WHERE p.id=profile_id AND p.status='approved'));
DROP POLICY IF EXISTS tm_save_delete ON public.tm_saved_tutors;
CREATE POLICY tm_save_delete ON public.tm_saved_tutors FOR DELETE TO authenticated USING(user_id=(SELECT auth.uid()) AND (SELECT public.tm_role())='student');
DROP POLICY IF EXISTS tm_request_read ON public.tm_contact_requests;
CREATE POLICY tm_request_read ON public.tm_contact_requests FOR SELECT TO authenticated USING(student_id=(SELECT auth.uid()) OR EXISTS(SELECT 1 FROM public.tm_tutor_profiles p WHERE p.id=profile_id AND p.user_id=(SELECT auth.uid())));
DROP POLICY IF EXISTS tm_audit_read ON public.tm_audit_log;
CREATE POLICY tm_audit_read ON public.tm_audit_log FOR SELECT TO authenticated USING((SELECT public.tm_role())='admin');

-- Private storage: only a photo explicitly attached to an APPROVED tutor profile is readable by visitors.
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES('tm-profile-photos','tm-profile-photos',false,2097152,ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT(id) DO UPDATE SET public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
DROP POLICY IF EXISTS tm_photo_insert ON storage.objects;
CREATE POLICY tm_photo_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='tm-profile-photos' AND split_part(name,'/',1)=(SELECT auth.uid())::text);
DROP POLICY IF EXISTS tm_photo_read ON storage.objects;
CREATE POLICY tm_photo_read ON storage.objects FOR SELECT TO anon,authenticated USING(bucket_id='tm-profile-photos' AND (split_part(name,'/',1)=(SELECT auth.uid())::text OR EXISTS(SELECT 1 FROM public.tm_tutor_profiles p WHERE p.photo_path=storage.objects.name AND (p.status='approved' OR (SELECT public.tm_role())='admin'))));
DROP POLICY IF EXISTS tm_photo_delete ON storage.objects;
CREATE POLICY tm_photo_delete ON storage.objects FOR DELETE TO authenticated USING(bucket_id='tm-profile-photos' AND split_part(name,'/',1)=(SELECT auth.uid())::text AND NOT EXISTS(SELECT 1 FROM public.tm_tutor_profiles p WHERE p.photo_path=storage.objects.name) AND NOT EXISTS(SELECT 1 FROM public.tm_accounts a WHERE a.photo_path=storage.objects.name));

REVOKE ALL ON public.tm_catalog,public.tm_accounts,public.tm_tutor_profiles,public.tm_profile_reviews,public.tm_saved_tutors,public.tm_contact_requests,public.tm_audit_log FROM anon,authenticated;
GRANT SELECT ON public.tm_catalog,public.tm_tutor_profiles TO anon,authenticated;
GRANT SELECT ON public.tm_accounts,public.tm_profile_reviews,public.tm_contact_requests,public.tm_audit_log TO authenticated;
GRANT SELECT,INSERT,DELETE ON public.tm_saved_tutors TO authenticated;
GRANT ALL ON public.tm_catalog,public.tm_accounts,public.tm_tutor_profiles,public.tm_profile_reviews,public.tm_saved_tutors,public.tm_contact_requests,public.tm_audit_log TO service_role;
REVOKE ALL ON FUNCTION public.tm_role(),public.tm_catalog_has(text,text),public.tm_valid_choices(text,text[]),public.tm_photo_owned(text),public.tm_update_account(jsonb),public.tm_save_preferences(jsonb),public.tm_save_tutor(jsonb,boolean),public.tm_review_tutor(uuid,text,text),public.tm_send_request(jsonb),public.tm_update_request(uuid,text),public.tm_my_requests() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_role() TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_update_account(jsonb),public.tm_save_preferences(jsonb),public.tm_save_tutor(jsonb,boolean),public.tm_review_tutor(uuid,text,text),public.tm_send_request(jsonb),public.tm_update_request(uuid,text),public.tm_my_requests() TO authenticated;


REVOKE ALL ON ALL FUNCTIONS IN SCHEMA tm_private FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION tm_private.tm_role() TO anon,authenticated;
GRANT EXECUTE ON FUNCTION tm_private.tm_update_account(jsonb),tm_private.tm_save_preferences(jsonb),tm_private.tm_save_tutor(jsonb,boolean),tm_private.tm_review_tutor(uuid,text,text),tm_private.tm_send_request(jsonb),tm_private.tm_update_request(uuid,text),tm_private.tm_my_requests() TO authenticated;
CREATE INDEX IF NOT EXISTS tm_saved_profile_fk ON public.tm_saved_tutors(profile_id);
CREATE INDEX IF NOT EXISTS tm_review_reviewer_fk ON public.tm_profile_reviews(reviewed_by);
CREATE INDEX IF NOT EXISTS tm_audit_actor_fk ON public.tm_audit_log(actor_id);

-- Seed values and final COMMIT are appended below by the source preparation script.

INSERT INTO public.tm_catalog(category,value,label_bn,sort_order) SELECT category,value,label_bn,sort_order FROM jsonb_to_recordset($catalog$[{"category":"districts","value":"Bagerhat","label_bn":"বাগেরহাট","sort_order":0},{"category":"districts","value":"Bandarban","label_bn":"বান্দরবান","sort_order":1},{"category":"districts","value":"Barguna","label_bn":"বরগুনা","sort_order":2},{"category":"districts","value":"Barishal","label_bn":"বরিশাল","sort_order":3},{"category":"districts","value":"Bhola","label_bn":"ভোলা","sort_order":4},{"category":"districts","value":"Bogura","label_bn":"বগুড়া","sort_order":5},{"category":"districts","value":"Brahmanbaria","label_bn":"ব্রাহ্মণবাড়িয়া","sort_order":6},{"category":"districts","value":"Chandpur","label_bn":"চাঁদপুর","sort_order":7},{"category":"districts","value":"Chapainawabganj","label_bn":"চাঁপাইনবাবগঞ্জ","sort_order":8},{"category":"districts","value":"Chattogram","label_bn":"চট্টগ্রাম","sort_order":9},{"category":"districts","value":"Chuadanga","label_bn":"চুয়াডাঙ্গা","sort_order":10},{"category":"districts","value":"Cox’s Bazar","label_bn":"কক্সবাজার","sort_order":11},{"category":"districts","value":"Cumilla","label_bn":"কুমিল্লা","sort_order":12},{"category":"districts","value":"Dhaka","label_bn":"ঢাকা","sort_order":13},{"category":"districts","value":"Dinajpur","label_bn":"দিনাজপুর","sort_order":14},{"category":"districts","value":"Faridpur","label_bn":"ফরিদপুর","sort_order":15},{"category":"districts","value":"Feni","label_bn":"ফেনী","sort_order":16},{"category":"districts","value":"Gaibandha","label_bn":"গাইবান্ধা","sort_order":17},{"category":"districts","value":"Gazipur","label_bn":"গাজীপুর","sort_order":18},{"category":"districts","value":"Gopalganj","label_bn":"গোপালগঞ্জ","sort_order":19},{"category":"districts","value":"Habiganj","label_bn":"হবিগঞ্জ","sort_order":20},{"category":"districts","value":"Jamalpur","label_bn":"জামালপুর","sort_order":21},{"category":"districts","value":"Jashore","label_bn":"যশোর","sort_order":22},{"category":"districts","value":"Jhalokati","label_bn":"ঝালকাঠি","sort_order":23},{"category":"districts","value":"Jhenaidah","label_bn":"ঝিনাইদহ","sort_order":24},{"category":"districts","value":"Joypurhat","label_bn":"জয়পুরহাট","sort_order":25},{"category":"districts","value":"Khagrachhari","label_bn":"খাগড়াছড়ি","sort_order":26},{"category":"districts","value":"Khulna","label_bn":"খুলনা","sort_order":27},{"category":"districts","value":"Kishoreganj","label_bn":"কিশোরগঞ্জ","sort_order":28},{"category":"districts","value":"Kurigram","label_bn":"কুড়িগ্রাম","sort_order":29},{"category":"districts","value":"Kushtia","label_bn":"কুষ্টিয়া","sort_order":30},{"category":"districts","value":"Lakshmipur","label_bn":"লক্ষ্মীপুর","sort_order":31},{"category":"districts","value":"Lalmonirhat","label_bn":"লালমনিরহাট","sort_order":32},{"category":"districts","value":"Madaripur","label_bn":"মাদারীপুর","sort_order":33},{"category":"districts","value":"Magura","label_bn":"মাগুরা","sort_order":34},{"category":"districts","value":"Manikganj","label_bn":"মানিকগঞ্জ","sort_order":35},{"category":"districts","value":"Meherpur","label_bn":"মেহেরপুর","sort_order":36},{"category":"districts","value":"Moulvibazar","label_bn":"মৌলভীবাজার","sort_order":37},{"category":"districts","value":"Munshiganj","label_bn":"মুন্সীগঞ্জ","sort_order":38},{"category":"districts","value":"Mymensingh","label_bn":"ময়মনসিংহ","sort_order":39},{"category":"districts","value":"Naogaon","label_bn":"নওগাঁ","sort_order":40},{"category":"districts","value":"Narail","label_bn":"নড়াইল","sort_order":41},{"category":"districts","value":"Narayanganj","label_bn":"নারায়ণগঞ্জ","sort_order":42},{"category":"districts","value":"Narsingdi","label_bn":"নরসিংদী","sort_order":43},{"category":"districts","value":"Natore","label_bn":"নাটোর","sort_order":44},{"category":"districts","value":"Netrokona","label_bn":"নেত্রকোণা","sort_order":45},{"category":"districts","value":"Nilphamari","label_bn":"নীলফামারী","sort_order":46},{"category":"districts","value":"Noakhali","label_bn":"নোয়াখালী","sort_order":47},{"category":"districts","value":"Pabna","label_bn":"পাবনা","sort_order":48},{"category":"districts","value":"Panchagarh","label_bn":"পঞ্চগড়","sort_order":49},{"category":"districts","value":"Patuakhali","label_bn":"পটুয়াখালী","sort_order":50},{"category":"districts","value":"Pirojpur","label_bn":"পিরোজপুর","sort_order":51},{"category":"districts","value":"Rajbari","label_bn":"রাজবাড়ী","sort_order":52},{"category":"districts","value":"Rajshahi","label_bn":"রাজশাহী","sort_order":53},{"category":"districts","value":"Rangamati","label_bn":"রাঙ্গামাটি","sort_order":54},{"category":"districts","value":"Rangpur","label_bn":"রংপুর","sort_order":55},{"category":"districts","value":"Satkhira","label_bn":"সাতক্ষীরা","sort_order":56},{"category":"districts","value":"Shariatpur","label_bn":"শরীয়তপুর","sort_order":57},{"category":"districts","value":"Sherpur","label_bn":"শেরপুর","sort_order":58},{"category":"districts","value":"Sirajganj","label_bn":"সিরাজগঞ্জ","sort_order":59},{"category":"districts","value":"Sunamganj","label_bn":"সুনামগঞ্জ","sort_order":60},{"category":"districts","value":"Sylhet","label_bn":"সিলেট","sort_order":61},{"category":"districts","value":"Tangail","label_bn":"টাঙ্গাইল","sort_order":62},{"category":"districts","value":"Thakurgaon","label_bn":"ঠাকুরগাঁও","sort_order":63},{"category":"subjects","value":"Mathematics","label_bn":null,"sort_order":0},{"category":"subjects","value":"Physics","label_bn":null,"sort_order":1},{"category":"subjects","value":"Chemistry","label_bn":null,"sort_order":2},{"category":"subjects","value":"Biology","label_bn":null,"sort_order":3},{"category":"subjects","value":"English","label_bn":null,"sort_order":4},{"category":"subjects","value":"Bangla","label_bn":null,"sort_order":5},{"category":"subjects","value":"ICT","label_bn":null,"sort_order":6},{"category":"subjects","value":"Accounting","label_bn":null,"sort_order":7},{"category":"subjects","value":"Economics","label_bn":null,"sort_order":8},{"category":"subjects","value":"General Science","label_bn":null,"sort_order":9},{"category":"subjects","value":"All subjects","label_bn":null,"sort_order":10},{"category":"classes","value":"Class 1–5","label_bn":null,"sort_order":0},{"category":"classes","value":"Class 6–8","label_bn":null,"sort_order":1},{"category":"classes","value":"Class 9–10 / SSC","label_bn":null,"sort_order":2},{"category":"classes","value":"Class 11–12 / HSC","label_bn":null,"sort_order":3},{"category":"classes","value":"O Level","label_bn":null,"sort_order":4},{"category":"classes","value":"A Level","label_bn":null,"sort_order":5},{"category":"classes","value":"Admission preparation","label_bn":null,"sort_order":6},{"category":"modes","value":"At student’s home","label_bn":null,"sort_order":0},{"category":"modes","value":"Online","label_bn":null,"sort_order":1},{"category":"modes","value":"At tutor’s place","label_bn":null,"sort_order":2},{"category":"days","value":"Sunday","label_bn":null,"sort_order":0},{"category":"days","value":"Monday","label_bn":null,"sort_order":1},{"category":"days","value":"Tuesday","label_bn":null,"sort_order":2},{"category":"days","value":"Wednesday","label_bn":null,"sort_order":3},{"category":"days","value":"Thursday","label_bn":null,"sort_order":4},{"category":"days","value":"Friday","label_bn":null,"sort_order":5},{"category":"days","value":"Saturday","label_bn":null,"sort_order":6}]$catalog$::jsonb) AS x(category text,value text,label_bn text,sort_order integer) ON CONFLICT(category,value) DO UPDATE SET label_bn=excluded.label_bn,sort_order=excluded.sort_order;

-- Remove RPC execution rights from legacy/platform trigger helpers; keep their triggers intact.
DO $secure_helpers$
BEGIN
 IF to_regprocedure('public.tm_handle_new_user()') IS NOT NULL THEN EXECUTE 'REVOKE ALL ON FUNCTION public.tm_handle_new_user() FROM PUBLIC,anon,authenticated'; END IF;
 IF to_regprocedure('public.rls_auto_enable()') IS NOT NULL THEN EXECUTE 'REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM PUBLIC,anon,authenticated'; END IF;
END $secure_helpers$;

NOTIFY pgrst, 'reload schema';
COMMIT;

-- Tutormela social authentication, status posts and email-code extension.
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
 IF p_role NOT IN ('student','tutor') THEN RAISE EXCEPTION 'Choose a student or tutor account.'; END IF;
 UPDATE public.tm_accounts SET role=p_role,onboarding_complete=true,updated_at=now() WHERE id=auth.uid() AND NOT onboarding_complete;
 IF NOT FOUND THEN RAISE EXCEPTION 'Your account type is already set.'; END IF;
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

-- Four-digit first-use email verification. Only the server may call these operations.
BEGIN;
CREATE TABLE IF NOT EXISTS tm_private.tm_signup_challenges (
 ticket_hash text PRIMARY KEY CHECK (ticket_hash ~ '^[0-9a-f]{64}$'),
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 email_hash text NOT NULL CHECK (email_hash ~ '^[0-9a-f]{64}$'),
 code_hash text NOT NULL CHECK (code_hash ~ '^[0-9a-f]{64}$'),
 expires_at timestamptz NOT NULL DEFAULT now()+interval '5 minutes',
 attempts integer NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 5),
 delivered boolean NOT NULL DEFAULT false,
 consumed_at timestamptz,
 completed_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS tm_signup_challenges_user_idx ON tm_private.tm_signup_challenges(user_id);
CREATE TABLE IF NOT EXISTS tm_private.tm_signup_rate_limits (
 bucket text PRIMARY KEY,
 window_start timestamptz NOT NULL DEFAULT now(),
 last_sent_at timestamptz NOT NULL DEFAULT now(),
 send_count integer NOT NULL DEFAULT 1
);
ALTER TABLE tm_private.tm_signup_challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE tm_private.tm_signup_rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON tm_private.tm_signup_challenges,tm_private.tm_signup_rate_limits FROM PUBLIC,anon,authenticated;
-- These tables intentionally have no client policies; all access is through the server-only function.
CREATE OR REPLACE FUNCTION tm_private.tm_signup_email(p_action text,p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c tm_private.tm_signup_challenges; r tm_private.tm_signup_rate_limits; u uuid; k text; maximum integer; session uuid;
BEGIN
 IF p_action='reserve' THEN
  IF coalesce(p_body->>'email_hash','') !~ '^[0-9a-f]{64}$' OR coalesce(p_body->>'ip_hash','') !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'Invalid verification request'; END IF;
  -- Lock both buckets in a consistent order. A shared IP has its own hourly limit.
  PERFORM pg_advisory_xact_lock(hashtextextended('email:'||(p_body->>'email_hash'),0));
  PERFORM pg_advisory_xact_lock(hashtextextended('ip:'||(p_body->>'ip_hash'),0));
  FOREACH k IN ARRAY ARRAY['email:'||(p_body->>'email_hash'),'ip:'||(p_body->>'ip_hash')] LOOP
   SELECT * INTO r FROM tm_private.tm_signup_rate_limits WHERE bucket=k;
   maximum:=CASE WHEN k LIKE 'email:%' THEN 5 ELSE 25 END;
   IF FOUND AND r.window_start>now()-interval '1 hour' THEN
    IF r.send_count>=maximum THEN RETURN jsonb_build_object('ok',false,'error','Too many codes requested. Please try again in an hour.'); END IF;
    IF k LIKE 'email:%' AND r.last_sent_at>now()-interval '60 seconds' THEN RETURN jsonb_build_object('ok',false,'error','Please wait one minute before requesting another code.'); END IF;
   END IF;
  END LOOP;
  FOREACH k IN ARRAY ARRAY['email:'||(p_body->>'email_hash'),'ip:'||(p_body->>'ip_hash')] LOOP
   INSERT INTO tm_private.tm_signup_rate_limits(bucket) VALUES(k) ON CONFLICT(bucket) DO UPDATE SET
    send_count=CASE WHEN tm_signup_rate_limits.window_start<=now()-interval '1 hour' THEN 1 ELSE tm_signup_rate_limits.send_count+1 END,
    window_start=CASE WHEN tm_signup_rate_limits.window_start<=now()-interval '1 hour' THEN now() ELSE tm_signup_rate_limits.window_start END,last_sent_at=now();
  END LOOP;
  DELETE FROM tm_private.tm_signup_rate_limits WHERE window_start<now()-interval '2 days';
  DELETE FROM tm_private.tm_signup_challenges WHERE expires_at<now()-interval '1 day';
  RETURN '{"ok":true}'::jsonb;
 END IF;
 IF p_action='lookup' THEN
  SELECT id INTO u FROM auth.users WHERE lower(email)=lower(p_body->>'email') LIMIT 1;
  RETURN jsonb_build_object('user_id',u);
 END IF;
 IF coalesce(p_body->>'ticket_hash','') !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'Invalid verification ticket'; END IF;
 IF p_action='prepare' THEN
  IF coalesce(p_body->>'email_hash','') !~ '^[0-9a-f]{64}$' OR coalesce(p_body->>'code_hash','') !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'Invalid code hash'; END IF;
  u:=(p_body->>'user_id')::uuid;
  PERFORM pg_advisory_xact_lock(hashtextextended(u::text,1));
  DELETE FROM tm_private.tm_signup_challenges WHERE user_id=u;
  INSERT INTO tm_private.tm_signup_challenges(ticket_hash,user_id,email_hash,code_hash) VALUES(p_body->>'ticket_hash',u,p_body->>'email_hash',p_body->>'code_hash') RETURNING * INTO c;
  RETURN jsonb_build_object('ok',true,'expiresAt',c.expires_at);
 END IF;
 SELECT * INTO c FROM tm_private.tm_signup_challenges WHERE ticket_hash=p_body->>'ticket_hash' FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','This code has expired. Please sign in again.'); END IF;
 IF p_action='complete' THEN
  session:=(p_body->>'session_id')::uuid;
  IF c.consumed_at IS NULL OR c.completed_at IS NOT NULL OR c.expires_at<=now() OR NOT EXISTS(SELECT 1 FROM auth.sessions s WHERE s.id=session AND s.user_id=c.user_id) THEN
   RETURN jsonb_build_object('ok',false,'error','This verification has expired. Please sign in again.');
  END IF;
  INSERT INTO tm_private.tm_verified_sessions(session_id,user_id) VALUES(session,c.user_id) ON CONFLICT(session_id) DO NOTHING;
  UPDATE tm_private.tm_signup_challenges SET completed_at=now() WHERE ticket_hash=c.ticket_hash;
  RETURN '{"ok":true}'::jsonb;
 END IF;
 IF c.consumed_at IS NOT NULL OR c.expires_at<=now() THEN RETURN jsonb_build_object('ok',false,'error','This code has expired. Please sign in again.'); END IF;
 IF p_action='recipient' THEN RETURN jsonb_build_object('ok',true,'user_id',c.user_id,'email_hash',c.email_hash); END IF;
 IF p_action='delivered' THEN
  UPDATE tm_private.tm_signup_challenges SET delivered=true WHERE ticket_hash=c.ticket_hash;
  RETURN '{"ok":true}'::jsonb;
 END IF;
 IF p_action='verify' THEN
  IF NOT c.delivered THEN RETURN jsonb_build_object('ok',false,'error','Request a new verification code.'); END IF;
  IF c.attempts>=5 THEN RETURN jsonb_build_object('ok',false,'error','Too many incorrect attempts. Request a new code.'); END IF;
  UPDATE tm_private.tm_signup_challenges SET attempts=attempts+1 WHERE ticket_hash=c.ticket_hash;
  IF c.code_hash IS DISTINCT FROM p_body->>'code_hash' THEN RETURN jsonb_build_object('ok',false,'error','That code is incorrect. Please check your email.'); END IF;
  UPDATE tm_private.tm_signup_challenges SET consumed_at=now() WHERE ticket_hash=c.ticket_hash;
  RETURN jsonb_build_object('ok',true,'user_id',c.user_id,'email_hash',c.email_hash);
 END IF;
 RAISE EXCEPTION 'Unknown verification operation';
END $$;
CREATE OR REPLACE FUNCTION public.tm_signup_email(p_action text,p_body jsonb)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_signup_email(p_action,p_body) $$;
REVOKE ALL ON FUNCTION tm_private.tm_signup_email(text,jsonb),public.tm_signup_email(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT USAGE ON SCHEMA tm_private TO service_role;
GRANT EXECUTE ON FUNCTION tm_private.tm_signup_email(text,jsonb),public.tm_signup_email(text,jsonb) TO service_role;
COMMIT;
