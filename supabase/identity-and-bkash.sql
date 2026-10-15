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
