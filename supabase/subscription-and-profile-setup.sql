-- Existing installations: retained posts, posting allowances, independent identity and prepared bKash order storage.
-- Run the complete file in Supabase SQL Editor. No posts or user accounts are deleted.
BEGIN;
-- Durable shared tutor posts, social likes and administrator-only removal.

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


-- Filtered tutor-post cards and subscription-ready posting limits.

CREATE TABLE IF NOT EXISTS public.tm_plans(
 id text PRIMARY KEY,name text NOT NULL,price_bdt integer NOT NULL CHECK(price_bdt>0),
 post_limit integer NOT NULL CHECK(post_limit BETWEEN 3 AND 1000),sort_order integer NOT NULL,enabled boolean NOT NULL DEFAULT true
);
INSERT INTO public.tm_plans(id,name,price_bdt,post_limit,sort_order) VALUES
 ('starter','Starter',300,6,1),('growth','Growth',500,15,2),('professional','Professional',800,30,3)
 ON CONFLICT(id) DO UPDATE SET name=excluded.name,price_bdt=excluded.price_bdt,post_limit=excluded.post_limit,sort_order=excluded.sort_order;
ALTER TABLE public.tm_plans ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tm_plans_read ON public.tm_plans;
CREATE POLICY tm_plans_read ON public.tm_plans FOR SELECT TO anon,authenticated USING(enabled);
REVOKE ALL ON public.tm_plans FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.tm_plans TO anon,authenticated;
GRANT ALL ON public.tm_plans TO service_role;
CREATE TABLE IF NOT EXISTS tm_private.tm_tutor_subscriptions(
 user_id uuid PRIMARY KEY REFERENCES public.tm_accounts(id) ON DELETE CASCADE,
 plan_id text NOT NULL REFERENCES public.tm_plans(id),period_start timestamptz NOT NULL,
 period_end timestamptz NOT NULL,status text NOT NULL CHECK(status IN ('active','expired','cancelled')),
 verified_payment_reference text NOT NULL CHECK(char_length(verified_payment_reference)>=6),
 CHECK(period_end>period_start)
);
CREATE TABLE IF NOT EXISTS tm_private.tm_plan_interests(
 user_id uuid NOT NULL REFERENCES public.tm_accounts(id) ON DELETE CASCADE,
 plan_id text NOT NULL REFERENCES public.tm_plans(id),created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(user_id,plan_id)
);
CREATE INDEX IF NOT EXISTS tm_plan_interest_plan ON tm_private.tm_plan_interests(plan_id);
CREATE INDEX IF NOT EXISTS tm_subscription_plan ON tm_private.tm_tutor_subscriptions(plan_id);
ALTER TABLE tm_private.tm_tutor_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE tm_private.tm_plan_interests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON tm_private.tm_tutor_subscriptions,tm_private.tm_plan_interests FROM PUBLIC,anon,authenticated;
GRANT ALL ON tm_private.tm_tutor_subscriptions,tm_private.tm_plan_interests TO service_role;
CREATE OR REPLACE FUNCTION tm_private.tm_post_quota() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE subscription tm_private.tm_tutor_subscriptions; plan public.tm_plans; used integer; allowance integer:=2;
BEGIN
 PERFORM tm_private.tm_assert_verified();
 IF public.tm_role() IS DISTINCT FROM 'tutor' THEN RAISE EXCEPTION 'Tutor account required.' USING ERRCODE='42501';END IF;
 SELECT * INTO subscription FROM tm_private.tm_tutor_subscriptions WHERE user_id=auth.uid() AND status='active' AND period_start<=now() AND period_end>now();
 IF FOUND THEN
  SELECT * INTO plan FROM public.tm_plans WHERE id=subscription.plan_id;
  allowance:=plan.post_limit;
  SELECT count(*) INTO used FROM public.tm_tutor_statuses WHERE user_id=auth.uid() AND created_at>=subscription.period_start AND created_at<subscription.period_end;
 ELSE
  SELECT count(*) INTO used FROM public.tm_tutor_statuses WHERE user_id=auth.uid();
 END IF;
 RETURN jsonb_build_object('plan',coalesce(plan.id,'free'),'name',coalesce(plan.name,'Free'),'limit',allowance,'used',used,'remaining',greatest(0,allowance-used),'canPost',used<allowance,'periodEnd',subscription.period_end,'paymentsEnabled',false);
END $$;
CREATE OR REPLACE FUNCTION public.tm_post_quota() RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_post_quota() $$;
REVOKE ALL ON FUNCTION public.tm_post_quota(),tm_private.tm_post_quota() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_post_quota(),tm_private.tm_post_quota() TO authenticated;
CREATE OR REPLACE FUNCTION tm_private.tm_enforce_post_quota() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE quota jsonb;
BEGIN
 -- Trusted migrations/payment services can maintain data; browser requests cannot select a user.
 IF auth.uid() IS NULL THEN RETURN NEW;END IF;
 IF NEW.user_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Post ownership mismatch.' USING ERRCODE='42501';END IF;
 -- Updating an existing identity through ON CONFLICT is an edit, not a new post.
 IF NEW.kind='identity' AND EXISTS(SELECT 1 FROM public.tm_tutor_statuses WHERE profile_id=NEW.profile_id AND kind='identity') THEN RETURN NEW;END IF;
 -- Lock the parent first to keep concurrent profile saves and posting in a consistent order.
 PERFORM 1 FROM public.tm_tutor_profiles WHERE id=NEW.profile_id FOR KEY SHARE;
 PERFORM pg_advisory_xact_lock(hashtextextended('tm-post-quota:'||NEW.user_id::text,0));
 quota:=tm_private.tm_post_quota();
 IF (quota->>'canPost')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'You have used your posting allowance. Choose a subscription plan to publish more.' USING ERRCODE='P0001';END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION tm_private.tm_enforce_post_quota() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS tm_enforce_post_quota ON public.tm_tutor_statuses;
CREATE TRIGGER tm_enforce_post_quota BEFORE INSERT ON public.tm_tutor_statuses FOR EACH ROW EXECUTE FUNCTION tm_private.tm_enforce_post_quota();
CREATE OR REPLACE FUNCTION tm_private.tm_register_plan_interest(p_plan text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM tm_private.tm_assert_verified();
 IF public.tm_role() IS DISTINCT FROM 'tutor' THEN RAISE EXCEPTION 'Tutor account required.' USING ERRCODE='42501';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.tm_plans WHERE id=p_plan AND enabled) THEN RAISE EXCEPTION 'This plan is not available.';END IF;
 INSERT INTO tm_private.tm_plan_interests(user_id,plan_id) VALUES(auth.uid(),p_plan) ON CONFLICT DO NOTHING;
 RETURN '{"saved":true,"paymentsEnabled":false,"activated":false}'::jsonb;
END $$;
CREATE OR REPLACE FUNCTION public.tm_register_plan_interest(p_plan text) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_register_plan_interest(p_plan) $$;
REVOKE ALL ON FUNCTION public.tm_register_plan_interest(text),tm_private.tm_register_plan_interest(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_register_plan_interest(text),tm_private.tm_register_plan_interest(text) TO authenticated;
-- Existing public profiles join the unified card feed; unpublished drafts stay private.
UPDATE public.tm_tutor_profiles SET feed_visible=true WHERE status='approved' AND NOT feed_visible;
INSERT INTO public.tm_tutor_statuses(user_id,profile_id,body,kind)
 SELECT p.user_id,p.id,left(coalesce(nullif(trim(p.about_en),''),nullif(trim(p.about_bn),''),'Available for tuition')||' · '||p.district,1200),'identity'
 FROM public.tm_tutor_profiles p WHERE p.feed_visible AND p.status IN ('pending','approved')
 ON CONFLICT(profile_id) WHERE kind='identity' DO NOTHING;
CREATE OR REPLACE FUNCTION tm_private.tm_browse_posts(p_filters jsonb DEFAULT '{}',p_sort text DEFAULT 'recommended',p_page integer DEFAULT 1) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE items jsonb; total bigint; budget integer:=100000; page integer:=greatest(1,least(coalesce(p_page,1),10000));
BEGIN
 IF length(coalesce(p_filters->>'q',''))>200 THEN RAISE EXCEPTION 'Use a shorter search.';END IF;
 IF coalesce(p_filters->>'budget','') ~ '^[0-9]{1,6}$' THEN budget:=(p_filters->>'budget')::integer;END IF;
 WITH matching AS (
  SELECT s.*,p.fee FROM public.tm_tutor_statuses s JOIN public.tm_tutor_profiles p ON p.id=s.profile_id
  WHERE s.withdrawn_at IS NULL AND p.feed_visible AND p.status IN ('pending','approved')
  AND (coalesce(p_filters->>'district','')='' OR p.district=p_filters->>'district')
  AND (NOT p_filters ? 'districts' OR p.district IN (SELECT jsonb_array_elements_text(p_filters->'districts')))
  AND (coalesce(p_filters->>'subject','')='' OR p_filters->>'subject'=ANY(p.subjects) OR 'All subjects'=ANY(p.subjects))
  AND (coalesce(p_filters->>'className','')='' OR p_filters->>'className'=ANY(p.classes))
  AND p.fee<=budget AND (coalesce(p_filters->>'mode','')='' OR p_filters->>'mode'=ANY(p.modes))
  AND (coalesce(p_filters->>'medium','')='' OR p.medium=p_filters->>'medium' OR p.medium='Bangla & English')
  AND (coalesce(p_filters->>'available','false')!='true' OR p.available)
  AND (coalesce(p_filters->>'q','')='' OR position(lower(p_filters->>'q') in lower(concat_ws(' ',p.name,p.university,p.district,p.areas,array_to_string(p.subjects,' '),s.body)))>0)
 ), counted AS (SELECT count(*) AS n FROM matching), selected AS (
  SELECT m.* FROM matching m ORDER BY CASE WHEN p_sort='low' THEN m.fee END ASC,CASE WHEN p_sort='high' THEN m.fee END DESC,m.created_at DESC,m.id DESC LIMIT 6 OFFSET (page-1)*6
 )
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',s.id,'kind',s.kind,'body',s.body,'created_at',s.created_at,'profile',to_jsonb(p)-'user_id','owner',coalesce(p.user_id=auth.uid(),false),'reactions',(SELECT count(*) FROM tm_private.tm_feed_reactions r WHERE r.post_id=s.id),'reacted',EXISTS(SELECT 1 FROM tm_private.tm_feed_reactions r WHERE r.post_id=s.id AND r.user_id=auth.uid()),'postViews',CASE WHEN p.user_id=auth.uid() AND public.tm_auth_session_ready() THEN (SELECT count(*) FROM tm_private.tm_feed_views v WHERE v.post_id=s.id) END,'profileViews',CASE WHEN p.user_id=auth.uid() AND public.tm_auth_session_ready() THEN (SELECT count(*) FROM tm_private.tm_feed_views v WHERE v.profile_id=p.id AND v.post_id IS NULL) END) ORDER BY CASE WHEN p_sort='low' THEN s.fee END ASC,CASE WHEN p_sort='high' THEN s.fee END DESC,s.created_at DESC,s.id DESC),'[]'::jsonb),(SELECT n FROM counted)
 INTO items,total FROM selected s JOIN public.tm_tutor_profiles p ON p.id=s.profile_id;
 RETURN jsonb_build_object('items',items,'total',total,'page',page,'pageSize',6);
END $$;
CREATE OR REPLACE FUNCTION public.tm_browse_posts(p_filters jsonb DEFAULT '{}',p_sort text DEFAULT 'recommended',p_page integer DEFAULT 1) RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_browse_posts(p_filters,p_sort,p_page) $$;
REVOKE ALL ON FUNCTION public.tm_browse_posts(jsonb,text,integer),tm_private.tm_browse_posts(jsonb,text,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_browse_posts(jsonb,text,integer),tm_private.tm_browse_posts(jsonb,text,integer) TO anon,authenticated;
NOTIFY pgrst,'reload schema';


COMMIT;

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

CREATE TABLE IF NOT EXISTS tm_private.tm_bkash_orders(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid NOT NULL REFERENCES public.tm_accounts(id),
 plan_id text NOT NULL REFERENCES public.tm_plans(id),amount integer NOT NULL CHECK(amount>0),
 invoice text NOT NULL UNIQUE,environment text NOT NULL CHECK(environment IN ('sandbox','live')),
 return_origin text NOT NULL,status text NOT NULL DEFAULT 'creating' CHECK(status IN ('creating','pending','paid','failed','cancelled')),
 payment_id text UNIQUE,transaction_id text UNIQUE,checkout_url text,execution_claimed_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(),paid_at timestamptz
);
ALTER TABLE tm_private.tm_bkash_orders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON tm_private.tm_bkash_orders FROM PUBLIC,anon,authenticated;
GRANT ALL ON tm_private.tm_bkash_orders TO service_role;
CREATE INDEX IF NOT EXISTS tm_bkash_orders_user ON tm_private.tm_bkash_orders(user_id,created_at);
CREATE UNIQUE INDEX IF NOT EXISTS tm_bkash_one_pending ON tm_private.tm_bkash_orders(user_id) WHERE status IN ('creating','pending');
CREATE OR REPLACE FUNCTION tm_private.tm_bkash_order(p_action text,p_data jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE o tm_private.tm_bkash_orders; plan public.tm_plans; uid uuid; new_id uuid;
BEGIN
 IF p_action='reserve' THEN
  uid:=(p_data->>'user')::uuid;
  PERFORM pg_advisory_xact_lock(hashtextextended(uid::text,812));
  IF NOT EXISTS(SELECT 1 FROM public.tm_accounts WHERE id=uid AND role='tutor') THEN RAISE EXCEPTION 'Tutor account required.'; END IF;
  IF EXISTS(SELECT 1 FROM tm_private.tm_tutor_subscriptions WHERE user_id=uid AND status='active' AND period_end>now()) THEN RAISE EXCEPTION 'Your current plan is still active.';END IF;
  SELECT * INTO o FROM tm_private.tm_bkash_orders WHERE user_id=uid AND status IN ('creating','pending') FOR UPDATE;
  IF FOUND THEN
   IF o.status='pending' AND o.plan_id=p_data->>'plan' AND o.environment=p_data->>'environment' AND o.return_origin=p_data->>'origin' THEN RETURN to_jsonb(o); END IF;
   IF o.status='creating' AND o.created_at<now()-interval '5 minutes' THEN UPDATE tm_private.tm_bkash_orders SET status='failed' WHERE id=o.id;
   ELSE RAISE EXCEPTION 'A checkout is already awaiting confirmation.';END IF;
  END IF;
  IF (SELECT count(*) FROM tm_private.tm_bkash_orders WHERE user_id=uid AND created_at>now()-interval '1 minute')>=3 OR (SELECT count(*) FROM tm_private.tm_bkash_orders WHERE user_id=uid AND created_at>now()-interval '1 day')>=20 THEN RAISE EXCEPTION 'Please wait before starting another checkout.';END IF;
  SELECT * INTO plan FROM public.tm_plans WHERE id=p_data->>'plan' AND enabled;
  IF NOT FOUND THEN RAISE EXCEPTION 'Plan unavailable.';END IF;
  new_id:=gen_random_uuid();
  INSERT INTO tm_private.tm_bkash_orders(id,user_id,plan_id,amount,invoice,environment,return_origin) VALUES(new_id,uid,plan.id,plan.price_bdt,'TM'||replace(new_id::text,'-',''),p_data->>'environment',p_data->>'origin') RETURNING * INTO o;
 ELSE
  SELECT * INTO o FROM tm_private.tm_bkash_orders WHERE id=(p_data->>'order')::uuid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF p_action='bind' AND o.status='creating' THEN
   UPDATE tm_private.tm_bkash_orders SET payment_id=p_data->>'paymentID',checkout_url=p_data->>'checkoutUrl',status='pending' WHERE id=o.id RETURNING * INTO o;
  ELSIF p_action='claim' THEN
   IF o.status!='pending' OR o.execution_claimed_at IS NOT NULL THEN RETURN jsonb_build_object('claimed',false); END IF;
   UPDATE tm_private.tm_bkash_orders SET execution_claimed_at=now() WHERE id=o.id;
   RETURN jsonb_build_object('claimed',true);
  ELSIF p_action='settle' THEN
   IF o.status='paid' THEN RETURN to_jsonb(o);END IF;
   IF o.status NOT IN ('pending','cancelled','failed') OR p_data->>'paymentID' IS DISTINCT FROM o.payment_id OR p_data->>'currency' IS DISTINCT FROM 'BDT' OR p_data->>'invoice' IS DISTINCT FROM o.invoice OR (p_data->>'amount')::numeric IS DISTINCT FROM o.amount::numeric OR p_data->>'transactionStatus' IS DISTINCT FROM 'Completed' OR char_length(coalesce(p_data->>'trxID',''))<6 THEN RAISE EXCEPTION 'Payment verification mismatch.';END IF;
   PERFORM pg_advisory_xact_lock(hashtextextended(o.user_id::text,812));
   IF o.environment='live' THEN
    IF EXISTS(SELECT 1 FROM tm_private.tm_tutor_subscriptions WHERE user_id=o.user_id AND status='active' AND period_end>now()) THEN RAISE EXCEPTION 'An active subscription already exists. Payment needs reconciliation.'; END IF;
    INSERT INTO tm_private.tm_tutor_subscriptions(user_id,plan_id,period_start,period_end,status,verified_payment_reference) VALUES(o.user_id,o.plan_id,now(),now()+interval '1 month','active','bkash:'||(p_data->>'trxID')) ON CONFLICT(user_id) DO UPDATE SET plan_id=excluded.plan_id,period_start=excluded.period_start,period_end=excluded.period_end,status='active',verified_payment_reference=excluded.verified_payment_reference;
   END IF;
   UPDATE tm_private.tm_bkash_orders SET status='paid',transaction_id=p_data->>'trxID',paid_at=now() WHERE id=o.id RETURNING * INTO o;
   INSERT INTO public.tm_audit_log(actor_id,action,resource_id) VALUES(o.user_id,'bkash_payment_verified',o.id);
  ELSIF p_action='fail' AND o.status='creating' THEN UPDATE tm_private.tm_bkash_orders SET status='failed' WHERE id=o.id RETURNING * INTO o;
  ELSIF p_action='cancel' AND o.status='pending' AND o.execution_claimed_at IS NULL THEN UPDATE tm_private.tm_bkash_orders SET status='cancelled' WHERE id=o.id RETURNING * INTO o;
  ELSIF p_action NOT IN ('read','bind','fail','cancel') THEN RAISE EXCEPTION 'Invalid payment action.';
  END IF;
 END IF;
 RETURN to_jsonb(o);
END $$;
CREATE OR REPLACE FUNCTION public.tm_bkash_order(p_action text,p_data jsonb) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT tm_private.tm_bkash_order(p_action,p_data) $$;
REVOKE ALL ON FUNCTION public.tm_bkash_order(text,jsonb),tm_private.tm_bkash_order(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tm_bkash_order(text,jsonb),tm_private.tm_bkash_order(text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;

-- Full teaching posts and public PDF documents (2026-10-15).
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

-- Exact profile links, private contact email and lasting favourites (2026-10-15).
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
