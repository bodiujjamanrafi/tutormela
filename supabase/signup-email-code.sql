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
