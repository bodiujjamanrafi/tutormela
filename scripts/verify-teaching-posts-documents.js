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


 const featureSQL=readFileSync('supabase/teaching-posts-and-documents.sql','utf8');await db.exec(featureSQL);await db.exec(featureSQL);check(true,'Teaching posts, PDFs and shortlist SQL rerun safely');
 const body={name:'Tutor One',university:'University',education:'Mathematics',district:'Dhaka',areas:'Dhanmondi',subjects:['Mathematics'],classes:['Class 9–10 / SSC'],modes:['Online'],days:['Sunday'],fee:5000,experience:'3 years',time:'Evening',medium:'Bangla & English',aboutEn:'Available to teach mathematics with care.',aboutBn:'',available:true};
 const save=async(id,b,publish=true,who=ids.tutor)=>(await as('authenticated',who,'SELECT public.tm_save_teaching_post($1,$2,$3,$4) AS r',[id,b,publish,publish])).rows[0].r;
 const workspace=async(who=ids.tutor)=>(await as('authenticated',who,'SELECT public.tm_workspace_posts() AS w')).rows[0].w;
 const browse=async(filters={})=>(await as('anon',null,"SELECT public.tm_browse_teaching_posts($1,'recommended',1) AS r",[filters])).rows[0].r;
 await denied(()=>save(null,body,true,ids.student),'Students cannot publish teaching posts');
 const first=await save(null,body);let w=await workspace();const profile=(await as('authenticated',ids.tutor,'SELECT * FROM public.tm_tutor_profiles WHERE user_id=$1',[ids.tutor])).rows[0];
 check(w.posts.length===1&&w.posts[0].details.fee===5000,'First full teaching post is saved independently');
 const draft=await save(null,{...body,fee:8000,district:'Sylhet',areas:'Zindabazar'},false);w=await workspace();
 check(w.drafts.length===1&&w.posts.length===1&&w.quota.used===1,'Drafts appear in Posts without consuming a posting slot');
 check((await browse()).total===1,'Private drafts never appear publicly');
 await denied(()=>save(draft.id,body,false,ids.other),'Other tutors cannot edit a private draft');
 await save(draft.id,{...body,fee:8000,district:'Sylhet',areas:'Zindabazar'});w=await workspace();
 check(w.posts.length===2&&!w.drafts.length,'Publishing a draft retains its ID and moves it into published Posts');
 const feed=await browse();check(feed.total===2&&feed.items.find(p=>p.id===first.id).profile.fee===5000&&feed.items.find(p=>p.id===draft.id).profile.fee===8000,'A later post never overwrites earlier teaching details');
 check((await browse({district:'Dhaka',budget:6000})).items[0].id===first.id,'Filters use each post’s own district and fee');
 check((await browse({district:'Sylhet'})).total===1,'A different district finds only the matching full post');
 await denied(()=>save(null,body),'A third free post is rejected on the server');
 await save(first.id,{...body,fee:5500});check((await workspace()).quota.used===2,'Editing a post does not consume an extra slot');
 await as('authenticated',ids.student,'SELECT public.tm_react_post($1,true)',[first.id]);
 check((await workspace()).posts.find(p=>p.id===first.id).reactions===1,'Each post keeps its own real reaction total');
 await as('authenticated',ids.student,'INSERT INTO public.tm_saved_tutors(user_id,profile_id) VALUES($1,$2)',[ids.student,profile.id]);
 check((await as('authenticated',ids.student,'SELECT * FROM public.tm_saved_tutors')).rows.length===1,'Students can save a visible tutor from a pending post to their private shortlist');
 check((await as('authenticated',ids.other,'SELECT * FROM public.tm_saved_tutors')).rows.length===0,'Student saved tutors stay private');
 const path=ids.tutor+'/cv.pdf';await as('authenticated',ids.tutor,"INSERT INTO storage.objects(bucket_id,name) VALUES('tm-tutor-documents',$1)",[path]);
 const doc=(await as('authenticated',ids.tutor,"SELECT public.tm_document_action('add',$1) AS d",[{path,title:'Teaching CV',kind:'cv',size:1000,shared:false}])).rows[0].d;
 const list=async()=>(await as('anon',null,'SELECT public.tm_list_documents($1) AS d',[profile.id])).rows[0].d;
 check((await list()).length===0,'PDFs remain private until explicitly shared');
 check((await as('anon',null,"SELECT * FROM storage.objects WHERE bucket_id='tm-tutor-documents'")).rows.length===0,'Private PDF files cannot be downloaded publicly');
 await as('authenticated',ids.tutor,"SELECT public.tm_document_action('share',$1)",[{id:doc.id,shared:true}]);
 check((await list()).length===1,'A shared PDF appears on the public tutor profile');
 check((await as('anon',null,"SELECT * FROM storage.objects WHERE name=$1",[path])).rows.length===1,'A visitor can download a shared PDF');
 await denied(()=>as('authenticated',ids.other,"SELECT public.tm_document_action('remove',$1)",[{id:doc.id}]),'Another tutor cannot remove a PDF');
 await denied(()=>as('authenticated',ids.other,"INSERT INTO storage.objects(bucket_id,name) VALUES('tm-tutor-documents',$1)",[ids.tutor+'/stolen.pdf']),'Another tutor cannot upload into your document folder');
 await as('authenticated',ids.tutor,"SELECT public.tm_document_action('share',$1)",[{id:doc.id,shared:false}]);
 check((await list()).length===0&&(await as('anon',null,"SELECT * FROM storage.objects WHERE name=$1",[path])).rows.length===0,'Making a PDF private revokes new public reads');
 await as('authenticated',ids.tutor,'SELECT public.tm_save_identity($1)',[{name:'Public Tutor Identity',district:'Dhaka',university:'Independent University',education:'BSc',introduction:'My personal introduction',introductionBn:''}]);
 const identity=(await as('anon',null,'SELECT public.tm_public_identity($1) AS i',[profile.id])).rows[0].i;
 check(identity.name==='Public Tutor Identity'&&identity.aboutEn==='My personal introduction'&&!('email' in identity)&&!('phone' in identity),'Public profile exposes the current identity without private login or contact data');
 // Exercise the new core feature on an existing project before the optional plan migration is applied.
 await db.exec('RESET ROLE');await db.exec('DROP FUNCTION public.tm_post_quota()');
 check((await as('authenticated',ids.other,'SELECT public.tm_teaching_quota() AS q')).rows[0].q.limit===2,'Core posting still enforces two free posts while optional billing setup is pending');
 await db.exec('RESET ROLE');await db.exec("UPDATE public.tm_tutor_statuses SET created_at=now()-interval '2 days'");
 await denied(()=>as('authenticated',ids.tutor,'SELECT public.tm_post_tutor_status($1,true)',['A legacy text endpoint cannot bypass the two-post rule.']),'Legacy posting endpoints cannot bypass the free allowance');
 console.log(`${count} full-post, draft, document, identity and student-save checks passed.`);
}finally{await db.close()}
