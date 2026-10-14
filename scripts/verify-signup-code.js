import {PGlite} from '@electric-sql/pglite'
import {readFileSync} from 'node:fs'
import assert from 'node:assert/strict'
const db=new PGlite(),user='11111111-1111-4111-8111-111111111111',other='22222222-2222-4222-8222-222222222222',session='33333333-3333-4333-8333-333333333333',wrongSession='44444444-4444-4444-8444-444444444444'
const ticket='a'.repeat(64),code='b'.repeat(64),wrong='c'.repeat(64)
let checks=0
const check=(value,label)=>{assert.ok(value,label);checks++}
async function op(action,body){return (await db.query('SELECT public.tm_signup_email($1,$2) AS r',[action,JSON.stringify(body)])).rows[0].r}
async function denied(role){await db.exec(`SET ROLE ${role}`);await assert.rejects(op('lookup',{email:'student@example.test'}),/permission denied/);await assert.rejects(db.query('SELECT * FROM tm_private.tm_signup_challenges'),/permission denied/);await db.exec('RESET ROLE');checks+=2}
try{
 await db.exec(`CREATE ROLE anon;CREATE ROLE authenticated;CREATE ROLE service_role BYPASSRLS;CREATE SCHEMA auth;CREATE SCHEMA tm_private;GRANT USAGE ON SCHEMA public,tm_private TO anon,authenticated,service_role;CREATE TABLE auth.users(id uuid PRIMARY KEY,email text);CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid REFERENCES auth.users(id));CREATE TABLE tm_private.tm_verified_sessions(session_id uuid PRIMARY KEY REFERENCES auth.sessions(id),user_id uuid REFERENCES auth.users(id),verified_at timestamptz DEFAULT now());`)
 const sql=readFileSync('supabase/signup-email-code.sql','utf8');await db.exec(sql);await db.exec(sql);checks++
 await db.query('INSERT INTO auth.users VALUES($1,$2),($3,$4)',[user,'student@example.test',other,'other@example.test']);await db.query('INSERT INTO auth.sessions VALUES($1,$2),($3,$4)',[session,user,wrongSession,other])
 await denied('anon');await denied('authenticated')
 await db.exec('SET ROLE service_role')
 check((await op('lookup',{email:'STUDENT@example.test'})).user_id===user,'Server-only lookup normalizes email')
 check((await op('reserve',{email_hash:code,ip_hash:wrong})).ok,'First request allowed')
 check(!(await op('reserve',{email_hash:code,ip_hash:wrong})).ok,'Immediate resend denied')
 await db.exec('RESET ROLE');await db.exec("UPDATE tm_private.tm_signup_rate_limits SET last_sent_at=now()-interval '61 seconds',send_count=5");await db.exec('SET ROLE service_role')
 check(!(await op('reserve',{email_hash:code,ip_hash:wrong})).ok,'Hourly request cap enforced')
 const prepare=()=>op('prepare',{ticket_hash:ticket,user_id:user,email_hash:'e'.repeat(64),code_hash:code})
 await prepare();check(!(await op('verify',{ticket_hash:ticket,code_hash:code})).ok,'Unsent code cannot verify')
 await op('delivered',{ticket_hash:ticket})
 for(let i=0;i<5;i++)check(!(await op('verify',{ticket_hash:ticket,code_hash:wrong})).ok,'Incorrect code denied')
 check(!(await op('verify',{ticket_hash:ticket,code_hash:code})).ok,'Correct code denied after five failures')
 await prepare();await op('delivered',{ticket_hash:ticket})
 check(!(await op('complete',{ticket_hash:ticket,session_id:session})).ok,'Cannot grant profile access before verification')
 check((await op('verify',{ticket_hash:ticket,code_hash:code})).user_id===user,'Correct code verifies owner')
 check(!(await op('verify',{ticket_hash:ticket,code_hash:code})).ok,'Consumed code cannot replay')
 check(!(await op('complete',{ticket_hash:ticket,session_id:wrongSession})).ok,'Cannot authorize another user session')
 check((await op('complete',{ticket_hash:ticket,session_id:session})).ok,'Verified owner session can open profile')
 check(!(await op('complete',{ticket_hash:ticket,session_id:session})).ok,'Session authorization is single-use')
 await prepare();await op('delivered',{ticket_hash:ticket});await db.exec('RESET ROLE');await db.exec("UPDATE tm_private.tm_signup_challenges SET expires_at=now()-interval '1 second'");await db.exec('SET ROLE service_role')
 check(!(await op('verify',{ticket_hash:ticket,code_hash:code})).ok,'Expired code denied')
 await prepare();const newTicket='d'.repeat(64);await op('prepare',{ticket_hash:newTicket,user_id:user,email_hash:'e'.repeat(64),code_hash:wrong})
 check(!(await op('recipient',{ticket_hash:ticket})).ok,'New request invalidates old ticket')
 await op('delivered',{ticket_hash:newTicket});check(!(await op('verify',{ticket_hash:newTicket,code_hash:code})).ok,'Previous code cannot verify new request')
 await db.exec('RESET ROLE');check((await db.query('SELECT count(*)::int AS n FROM tm_private.tm_verified_sessions')).rows[0].n===1,'Only verified owner session stored')
 console.log(`${checks} signup OTP checks passed: permissions, limits, expiry, attempt lockout, replay, resend, and session ownership.`)
}finally{await db.close()}
