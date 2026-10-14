BEGIN;
DROP POLICY IF EXISTS tm_no_client_access ON tm_private.tm_auth_config;
CREATE POLICY tm_no_client_access ON tm_private.tm_auth_config FOR ALL TO anon,authenticated USING(false) WITH CHECK(false);
DROP POLICY IF EXISTS tm_no_client_access ON tm_private.tm_login_challenges;
CREATE POLICY tm_no_client_access ON tm_private.tm_login_challenges FOR ALL TO anon,authenticated USING(false) WITH CHECK(false);
DROP POLICY IF EXISTS tm_no_client_access ON tm_private.tm_verified_sessions;
CREATE POLICY tm_no_client_access ON tm_private.tm_verified_sessions FOR ALL TO anon,authenticated USING(false) WITH CHECK(false);

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
COMMIT;
