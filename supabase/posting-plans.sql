-- Filtered tutor-post cards and subscription-ready posting limits.
BEGIN;
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
