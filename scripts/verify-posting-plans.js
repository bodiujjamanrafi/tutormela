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
 const body={name:'Test Tutor',university:'University',education:'Mathematics',district:'Dhaka',areas:'Dhanmondi',subjects:['Mathematics'],classes:['Class 9–10 / SSC'],modes:['Online'],days:['Sunday'],fee:6000,experience:'3 years',time:'Evening',medium:'Bangla & English',aboutEn:'Available for evening Mathematics tuition.',aboutBn:'',available:true};

 await db.exec(readFileSync('supabase/posting-plans.sql','utf8'));
 await db.exec(readFileSync('supabase/posting-plans.sql','utf8'));
 check(true,'Posting plans and filtered feed schema rerun safely');
 const plans=(await as('anon',null,'SELECT price_bdt,post_limit FROM public.tm_plans ORDER BY sort_order')).rows;
 check(plans.map(p=>p.price_bdt).join(',')==='300,500,800','Public plans match the requested monthly prices');
 check(plans.map(p=>p.post_limit).join(',')==='6,15,30','Paid posting allowances are explicit');
 await denied(()=>as('authenticated',ids.student,'SELECT public.tm_post_quota()'),'Students cannot receive tutor posting allowances');
 await denied(()=>as('authenticated',ids.student,"SELECT public.tm_register_plan_interest('growth')"),'Students cannot register a tutor subscription');
 await denied(()=>as('authenticated',ids.tutor,"UPDATE public.tm_plans SET price_bdt=1"),'Clients cannot edit plan prices');
 await denied(()=>as('authenticated',ids.tutor,'SELECT * FROM tm_private.tm_tutor_subscriptions'),'Private subscription records are not exposed');
 const quota=async (id=ids.tutor)=>(await as('authenticated',id,'SELECT public.tm_post_quota() AS q')).rows[0].q;
 check((await quota()).remaining===2,'A new tutor receives exactly two free posts');
 let profile=(await as('authenticated',ids.tutor,'SELECT * FROM public.tm_save_shared_profile($1,true,true)',[body])).rows[0];
 check((await quota()).used===1,'The shared identity counts as the first free post');
 async function agePosts(){await db.exec('RESET ROLE');await db.exec("UPDATE public.tm_tutor_statuses SET created_at=now()-interval '2 days'")}
 await agePosts();
 const post=(await as('authenticated',ids.tutor,'SELECT public.tm_post_tutor_status($1,true) AS id',['I am available for evening Mathematics tuition.'])).rows[0].id;
 check((await quota()).used===2&&!(await quota()).canPost,'The second post exhausts the free allowance');
 await agePosts();
 await denied(()=>as('authenticated',ids.tutor,'SELECT public.tm_post_tutor_status($1,true)',['A third free post must be rejected at the database.']),'The database rejects a third free post');
 await as('authenticated',ids.tutor,'SELECT public.tm_save_shared_profile($1,true,true)',[{...body,name:'Updated tutor'}]);
 check((await quota()).used===2,'Editing a shared profile does not consume a post');
 await as('authenticated',ids.admin,'SELECT public.tm_set_status_visibility($1,false)',[post]);
 check((await quota()).used===2,'Admin removal does not reset the free allowance');
 await as('authenticated',ids.admin,'SELECT public.tm_set_status_visibility($1,true)',[post]);
 const interest=(await as('authenticated',ids.tutor,"SELECT public.tm_register_plan_interest('growth') AS r")).rows[0].r;
 await as('authenticated',ids.tutor,"SELECT public.tm_register_plan_interest('growth')");
 check(interest.saved&&!interest.activated&&!interest.paymentsEnabled&&(await quota()).plan==='free','Registering interest never grants a paid allowance or charges a payment');
 await db.exec('RESET ROLE');check((await db.query('SELECT count(*)::int AS n FROM tm_private.tm_plan_interests')).rows[0].n===1,'Repeated plan interest is deduplicated');
 await denied(()=>as('authenticated',ids.tutor,"INSERT INTO tm_private.tm_tutor_subscriptions(user_id,plan_id,period_start,period_end,status,verified_payment_reference) VALUES($1,'growth',now(),now()+interval '1 month','active','forged')",[ids.tutor]),'Clients cannot activate their own subscription');
 await db.exec('RESET ROLE');await db.query("INSERT INTO tm_private.tm_tutor_subscriptions(user_id,plan_id,period_start,period_end,status,verified_payment_reference) VALUES($1,'growth',now()-interval '20 days',now()+interval '10 days','active','TEST-FIXTURE-VERIFIED')",[ids.tutor]);
 check((await quota()).limit===15&&(await quota()).used===2,'A verified active subscription uses the selected monthly allowance');
 for(let i=0;i<13;i++){await agePosts();await as('authenticated',ids.tutor,'SELECT public.tm_post_tutor_status($1,true)',['Paid allowance test teaching update '+i]);}
 check((await quota()).used===15&&!(await quota()).canPost,'Monthly posting limits are enforced by stored posts');
 await agePosts();await denied(()=>as('authenticated',ids.tutor,'SELECT public.tm_post_tutor_status($1,true)',['A sixteenth post must not exceed the monthly allowance.']),'The database rejects a post above the paid allowance');
 await db.exec('RESET ROLE');await db.query("UPDATE tm_private.tm_tutor_subscriptions SET period_end=now()-interval '1 minute' WHERE user_id=$1",[ids.tutor]);
 check((await quota()).plan==='free'&&!(await quota()).canPost,'Expired plans revert to the free limit without creating fresh free slots');
 const browse=async(filters={},sort='recommended',page=1,role='anon',id=null)=>(await as(role,id,'SELECT public.tm_browse_posts($1,$2,$3) AS r',[filters,sort,page])).rows[0].r;
 const first=await browse(),second=await browse({},'recommended',2);
 check(first.total===15&&first.items.length===6&&second.items.length===6,'Unified cards retain all posts after plan expiry and paginate by six');
 check(!first.items.some(p=>second.items.some(q=>p.id===q.id)),'Browse pagination does not repeat posts');
 check(first.items.every(p=>p.profileViews===null&&p.postViews===null&&!p.profile.user_id),'Public cards do not expose private owner analytics or account identifiers');
 check((await browse({subject:'Mathematics',district:'Dhaka',budget:6000})).total===15,'Subject, district and budget filters apply to status and identity posts');
 check((await browse({budget:500})).total===0,'Budget filtering excludes unaffordable tutors');
 check((await browse({districts:['Sylhet']})).total===0,'Division district groups filter the card feed');
 check((await browse({q:'Paid allowance test'})).total===13,'Text search includes tutor status bodies');
 await denied(()=>as('anon',null,'SELECT public.tm_react_post($1,true)',[post]),'Only signed-in accounts can like posts');
 await as('authenticated',ids.student,'SELECT public.tm_react_post($1,true)',[post]);await as('authenticated',ids.student,'SELECT public.tm_react_post($1,true)',[post]);
 const visitor='99999999-9999-4999-8999-999999999999';
 await as('authenticated',ids.student,"SELECT public.tm_record_view('profile',$1,$2)",[profile.id,visitor]);await as('authenticated',ids.student,"SELECT public.tm_record_view('profile',$1,$2)",[profile.id,visitor]);
 const owner=await browse({},'recommended',1,'authenticated',ids.tutor);
 check(owner.items.every(p=>p.profileViews===1),'Owners see deduplicated profile views beneath their shared posts');
 const liked=(await browse({q:'I am available'})).items[0];check(liked.reactions===1,'Card likes are read from the persisted database reaction record');
 await db.exec('RESET ROLE');check((await db.query('SELECT count(*)::int AS n FROM public.tm_tutor_statuses')).rows[0].n===15,'No post is deleted on subscription expiry');
 console.log(`\n${count} posting-plan, unified-card, security and engagement checks passed.`);
}catch(e){console.error('Posting plan verification failed:',e.message);process.exitCode=1}finally{await db.close()}
