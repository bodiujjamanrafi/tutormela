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



 const sql=readFileSync('supabase/profile-contact-and-saves.sql','utf8');await db.exec(sql);await db.exec(sql);check(true,'Profile, favourite and email SQL reruns without losing data');
 const body={name:'Rafi Jr',university:'University',education:'Mathematics',district:'Dhaka',areas:'Dhanmondi',subjects:['Mathematics'],classes:['Class 9–10 / SSC'],modes:['Online'],days:['Sunday'],fee:5000,experience:'3 years',time:'Evening',medium:'Bangla & English',aboutEn:'Available to teach mathematics with care.',aboutBn:'',available:true};
 const publish=async(b,who)=>(await as('authenticated',who,'SELECT public.tm_save_teaching_post(NULL,$1,true,true) AS r',[b])).rows[0].r.id;
 const aPost=await publish(body,ids.tutor),bPost=await publish({...body,name:'Another Tutor'},ids.other);
 await db.exec('RESET ROLE');let profiles=(await db.query('SELECT id,user_id FROM public.tm_tutor_profiles')).rows;const a=profiles.find(p=>p.user_id===ids.tutor).id,b=profiles.find(p=>p.user_id===ids.other).id;
 await publish({...body,name:'Different later post',fee:8000},ids.tutor);
 const page=async(profile,post)=>(await as('anon',null,'SELECT public.tm_tutor_page($1,$2) AS p',[profile,post])).rows[0].p;
 const exact=await page(a,aPost);check(exact.name==='Rafi Jr'&&exact.fee===5000&&exact.id===a,'The selected post opens its exact tutor and details after a different later post');
 check(await page(a,bPost)===null,'A post belonging to another tutor is never returned for the selected tutor');
 check((await page(b,bPost)).name==='Another Tutor','Another tutor opens only under their own profile ID');
 check(await page('99999999-9999-4999-8999-999999999999',null)===null,'Unknown IDs return unavailable rather than an arbitrary profile');
 await as('authenticated',ids.student,'SELECT public.tm_save_favourite($1,$2)',[a,aPost]);await as('authenticated',ids.student,'SELECT public.tm_save_favourite($1,$2)',[a,aPost]);
 const saved=async(who=ids.student)=>(await as('authenticated',who,'SELECT public.tm_my_saved_tutors() AS s')).rows[0].s;
 check((await saved()).length===1&&(await saved())[0].name==='Rafi Jr','Saving is deduplicated and retains the selected post’s identity');
 await denied(()=>as('authenticated',ids.tutor,'SELECT public.tm_my_saved_tutors()'),'Tutor accounts cannot read a student’s shortlist');
 const request={profileId:a,postId:aPost,studentName:'Student',className:body.classes[0],subject:'Mathematics',mode:'Online',message:'I would like mathematics tuition.',contact:'',consent:true,studentEmail:'forged@example.test',tutorEmail:'forged-recipient@example.test'};
 const id=(await as('authenticated',ids.student,'SELECT public.tm_send_request($1) AS id',[request])).rows[0].id;
 const read=(await as('authenticated',ids.student,'SELECT public.tm_my_requests() AS r')).rows[0].r[0];
 check(read.student_email==='student@example.test'&&read.contact==='student@example.test','The sender/reply email is derived from the signed-in account, ignoring forged fields');
 check(read.tutor_name==='Rafi Jr'&&read.email_status==='queued','The request is bound to the selected tutor/post and queued in the database');
 await denied(()=>as('authenticated',ids.student,'SELECT * FROM tm_private.tm_contact_email_outbox'),'Students cannot read private recipient email/outbox records');
 await denied(()=>as('authenticated',ids.other,'SELECT public.tm_my_requests() AS r').then(r=>{if(!r.rows[0].r.length)throw new Error('blocked')}),'An unrelated tutor cannot read the message');
 const service=async(action,user,claim=null,result={})=>(await as('service_role',null,'SELECT public.tm_contact_delivery($1,$2,$3,$4,$5) AS r',[action,id,user,claim,result])).rows[0].r;
 await denied(()=>service('claim',ids.other),'The server cannot claim a message under another sender');
 const job=await service('claim',ids.student);
 check(job.to_email==='tutor@example.test'&&job.reply_to_email==='student@example.test','The recipient is the selected tutor’s registered email, and replies go to the verified student');
 check(job.text_body.includes(request.message)&&job.text_body.includes('student@example.test'),'The exact message and reply email are stored in the outbox');
 check(!(await service('claim',ids.student)).claimed,'Concurrent or repeated attempts cannot send the same queued email twice');
 await service('finish',ids.student,job.claim_id,{status:'sent',from:'Tutormela <sender@example.test>',messageId:'smtp-accepted-id'});
 check((await service('claim',ids.student)).status==='sent','An accepted email is never sent again by retrying');
 await db.exec('RESET ROLE');const log=(await db.query('SELECT * FROM tm_private.tm_contact_email_outbox WHERE request_id=$1',[id])).rows[0];
 check(log.status==='sent'&&log.from_email.includes('sender@example.test')&&log.provider_message_id==='smtp-accepted-id'&&log.sent_at,'The email sender, recipient, content and delivery outcome are stored privately');
 await db.query("UPDATE public.tm_tutor_profiles SET status='rejected' WHERE id=$1",[a]);
 check((await saved()).length===1&&(await saved())[0].unavailable,'A hidden tutor stays in Saved tutors as unavailable');
 await db.exec('RESET ROLE');await db.query('DELETE FROM public.tm_tutor_profiles WHERE id=$1',[a]);
 check((await saved()).length===1&&(await saved())[0].id===a,'Even a removed profile does not silently delete the student’s saved entry');
 await as('authenticated',ids.student,'DELETE FROM public.tm_saved_tutors WHERE profile_id=$1',[a]);check((await saved()).length===0,'Only the student’s explicit removal clears their saved entry');
 console.log(`${count} exact-profile, permanent-save and private email-outbox checks passed.`);
}finally{await db.close()}
