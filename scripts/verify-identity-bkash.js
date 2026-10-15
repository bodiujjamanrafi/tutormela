import {PGlite} from '@electric-sql/pglite';
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const db=new PGlite();let count=0;const sessionIds={};
const check=(v,m)=>{assert.ok(v,m);count++;console.log('✓ '+m)};
const ids={student:'11111111-1111-4111-8111-111111111111',tutor:'22222222-2222-4222-8222-222222222222',other:'33333333-3333-4333-8333-333333333333',admin:'44444444-4444-4444-8444-444444444444'};
async function as(role,id,sql,args=[]){await db.exec(`RESET ROLE; SET ROLE ${role};`);await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)",[id||'']);await db.query("SELECT set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:id,session_id:sessionIds[id],amr:[{method:'password'}]})]);return db.query(sql,args)}
async function denied(fn,m){let rejected=false;try{await fn()}catch{rejected=true}check(rejected,m)}
try{
 await db.exec(`CREATE ROLE anon; CREATE ROLE supabase_auth_admin; CREATE ROLE authenticated; CREATE ROLE service_role BYPASSRLS; CREATE SCHEMA auth; CREATE SCHEMA storage; GRANT USAGE ON SCHEMA auth,storage,public TO anon,authenticated,service_role;
 CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,raw_user_meta_data jsonb DEFAULT '{}',raw_app_meta_data jsonb DEFAULT '{}');
 CREATE TABLE auth.sessions(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE);
 CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$ SELECT coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb,'{}'::jsonb) $$;
 CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
 CREATE TABLE storage.buckets(id text PRIMARY KEY,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
 CREATE TABLE storage.objects(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),bucket_id text REFERENCES storage.buckets(id),name text,UNIQUE(bucket_id,name));ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;GRANT SELECT,INSERT,DELETE ON storage.objects TO anon,authenticated;`);
 await db.exec('GRANT USAGE ON SCHEMA auth TO supabase_auth_admin; GRANT INSERT ON auth.users TO supabase_auth_admin;');

 await db.exec(readFileSync('supabase/schema.sql','utf8'));
 const feature=readFileSync('supabase/feed-and-profiles.sql','utf8');await db.exec(feature);await db.exec(feature);const community=readFileSync('supabase/community-social.sql','utf8');await db.exec(community);await db.exec(community);check(true,'Feed and social rules execute and rerun safely');
 await db.exec('SET ROLE supabase_auth_admin');
 for(const [role,id] of Object.entries(ids)){await db.query('INSERT INTO auth.users(id,email,raw_user_meta_data) VALUES($1,$2,$3)',[id,`${role}@example.test`,JSON.stringify({name:`Test ${role}`,role:role==='other'?'tutor':role})])}
 await db.exec('RESET ROLE');for(const id of Object.values(ids)){sessionIds[id]=(await db.query('INSERT INTO auth.sessions(user_id) VALUES($1) RETURNING id',[id])).rows[0].id}
 await db.query("UPDATE public.tm_accounts SET role='admin' WHERE id=$1",[ids.admin]);

 const addition=readFileSync('supabase/identity-and-bkash.sql','utf8');await db.exec(addition);await db.exec(addition);check(true,'Identity and payment SQL reruns safely');
 const before=await as('authenticated',ids.tutor,'SELECT public.tm_post_quota() AS q');
 await db.exec('RESET ROLE');await db.query("UPDATE public.tm_accounts SET phone='PRIVATE',preferences='{\"otherPreference\":true}' WHERE id=$1",[ids.tutor]);
 const identity={name:'Updated Tutor',photo_path:null,district:'Dhaka',university:'University',education:'Mathematics',introduction:'My independent introduction',introductionBn:'আমার পরিচয়'};
 await as('authenticated',ids.tutor,'SELECT public.tm_save_identity($1)',[identity]);
 const account=(await as('authenticated',ids.tutor,'SELECT * FROM public.tm_accounts WHERE id=$1',[ids.tutor])).rows[0];
 check(account.name==='Updated Tutor'&&account.tutor_identity.introduction===identity.introduction,'Identity and introduction persist in the account');
 check(account.phone==='PRIVATE'&&account.preferences.otherPreference,'Identity preserves private contact details and unrelated preferences');
 const after=await as('authenticated',ids.tutor,'SELECT public.tm_post_quota() AS q');
 check(before.rows[0].q.used===after.rows[0].q.used,'Saving identity does not publish or consume a post');
 await denied(()=>as('authenticated',ids.student,'SELECT public.tm_save_identity($1)',[identity]),'Students cannot create a tutor identity');
 await denied(()=>as('anon',null,'SELECT public.tm_save_identity($1)',[identity]),'Anonymous visitors cannot edit identity');
 await denied(()=>as('authenticated',ids.other,'SELECT * FROM public.tm_accounts WHERE id=$1',[ids.tutor]).then(r=>{if(!r.rows.length)throw new Error('blocked')}),'Other users cannot read private identity');
 await denied(()=>as('authenticated',ids.tutor,"SELECT public.tm_bkash_order('reserve',$1)",[{user:ids.tutor,plan:'professional',origin:'http://localhost:5173',environment:'live'}]),'A browser cannot create or settle service payment orders');
 const service=async(action,data)=>(await as('service_role',null,'SELECT public.tm_bkash_order($1,$2) AS o',[action,data])).rows[0].o;
 let o=await service('reserve',{user:ids.tutor,plan:'starter',amount:1,origin:'http://localhost:5173',environment:'sandbox'});
 check(o.amount===300,'Order amount is loaded from the database, ignoring supplied prices');
 await service('bind',{order:o.id,paymentID:'sandbox-payment',checkoutUrl:'https://sandbox.bka.sh/test'});
 await denied(()=>service('settle',{order:o.id,paymentID:'sandbox-payment',invoice:o.invoice,amount:1,currency:'BDT',transactionStatus:'Completed',trxID:'SANDBOX-TRANSACTION'}),'Amount mismatch prevents settlement');
 let claim=await service('claim',{order:o.id});check(claim.claimed&&!(await service('claim',{order:o.id})).claimed,'Payment execution can be claimed only once');
 const proof={order:o.id,paymentID:'sandbox-payment',invoice:o.invoice,amount:300,currency:'BDT',transactionStatus:'Completed',trxID:'SANDBOX-TRANSACTION'};
 await service('settle',proof);await service('settle',proof);
 check((await as('authenticated',ids.tutor,'SELECT public.tm_post_quota() AS q')).rows[0].q.plan==='free','Sandbox payments never activate a real subscription');
 o=await service('reserve',{user:ids.tutor,plan:'growth',origin:'http://localhost:5173',environment:'live'});
 await service('bind',{order:o.id,paymentID:'live-payment',checkoutUrl:'https://payment.bka.sh/test'});
 const repeat=await service('reserve',{user:ids.tutor,plan:'growth',origin:'http://localhost:5173',environment:'live'});check(repeat.id===o.id,'Repeated starts reuse the same pending checkout');
 await denied(()=>service('reserve',{user:ids.tutor,plan:'starter',origin:'http://localhost:5173',environment:'live'}),'A different plan cannot start an overlapping checkout');
 const liveProof={order:o.id,paymentID:'live-payment',invoice:o.invoice,amount:500,currency:'BDT',transactionStatus:'Completed',trxID:'LIVE-TRANSACTION'};
 await denied(()=>service('settle',{...liveProof,currency:'USD'}),'Wrong currency is rejected');
 await denied(()=>service('settle',{...liveProof,invoice:'FORGED'}),'Wrong invoice is rejected');
 await denied(()=>service('settle',{...liveProof,paymentID:'FORGED'}),'Wrong payment reference is rejected');
 await denied(()=>service('settle',{...liveProof,transactionStatus:'Initiated'}),'An incomplete payment never activates a subscription');
 await service('settle',liveProof);const quota=(await as('authenticated',ids.tutor,'SELECT public.tm_post_quota() AS q')).rows[0].q;
 check(quota.plan==='growth'&&quota.limit===15,'A verified live payment grants exactly the purchased allowance');
 const settled=await service('settle',liveProof);check(settled.status==='paid','Duplicate settlement is idempotent');
 await denied(()=>service('reserve',{user:ids.tutor,plan:'professional',origin:'http://localhost:5173',environment:'live'}),'An active subscription blocks another charge');
 await denied(()=>as('authenticated',ids.tutor,'SELECT * FROM tm_private.tm_bkash_orders'),'Private payment records cannot be read by clients');
 console.log(`${count} identity/payment checks passed.`);
}finally{await db.close()}
