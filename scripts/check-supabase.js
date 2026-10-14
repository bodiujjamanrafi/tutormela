import {loadEnv} from 'vite';
import {createClient} from '@supabase/supabase-js';
import assert from 'node:assert/strict';
const env=loadEnv('development',process.cwd(),'VITE_');
assert.ok(env.VITE_SUPABASE_URL&&env.VITE_SUPABASE_PUBLISHABLE_KEY,'Supabase environment configuration is required');
const client=createClient(env.VITE_SUPABASE_URL,env.VITE_SUPABASE_PUBLISHABLE_KEY,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});
let count=0;
const check=(v,m)=>{assert.ok(v,m);count++;console.log('✓ '+m)};
try{
 const {data:catalog,error}=await client.from('tm_catalog').select('category,value');
 if(error)throw new Error(error.message);
 check(catalog.filter(r=>r.category==='districts').length===64,'Live database provides all 64 districts');
 const profiles=await client.from('tm_tutor_profiles').select('id,status').eq('status','approved');
 check(!profiles.error&&profiles.data.every(p=>p.status==='approved'),'Approved tutor search is connected');
 for(const table of ['tm_accounts','tm_contact_requests','tm_profile_reviews','tm_audit_log']){
  const result=await client.from(table).select('*').limit(1);
  check(Boolean(result.error),'Anonymous access is denied for '+table);
 }
 const requests=await client.rpc('tm_my_requests');
 check(Boolean(requests.error),'Anonymous users cannot call private request actions');
 const response=await fetch(env.VITE_SUPABASE_URL+'/auth/v1/settings',{headers:{apikey:env.VITE_SUPABASE_PUBLISHABLE_KEY}});
 check(response.ok,'Supabase Auth is reachable');
 const auth=await response.json();
 check(auth.external?.email===true,'Email sign-in is enabled');
 const statuses=await client.from('tm_tutor_statuses').select('id').limit(1);
 check(!statuses.error,'Public teaching updates are connected to the live database');
 const gate=await client.rpc('tm_email_code_enabled');
 check(!gate.error&&typeof gate.data==='boolean','Email verification activation state is available');
 console.log('Email-code enforcement:',gate.data?'enabled':'awaiting SMTP setup');
 console.log('OAuth provider setup:',JSON.stringify({google:auth.external?.google===true,facebook:auth.external?.facebook===true}));
 for(const name of ['tm_issue_email_code','tm_verify_email_code']){
  const r=await client.rpc(name,{p_user:'00000000-0000-4000-8000-000000000001',p_session:'00000000-0000-4000-8000-000000000002',p_hash:'a'.repeat(64)});
  check(Boolean(r.error),'Anonymous clients cannot call '+name);
 }
 const edge=await fetch(env.VITE_SUPABASE_URL+'/functions/v1/email-login-code',{method:'POST',headers:{apikey:env.VITE_SUPABASE_PUBLISHABLE_KEY,'Content-Type':'application/json',Origin:'http://127.0.0.1:5173'},body:JSON.stringify({action:'verify',code:'0000'})});
 if(edge.status!==401)throw new Error('Unauthenticated email-code endpoint returned HTTP '+edge.status+': '+(await edge.text()).slice(0,200));check(true,'Email-code Edge Function rejects unauthenticated requests');
 console.log(`\n${count} read-only live connection checks passed. No accounts, emails or records were created.`);
}catch(e){console.error('Connection verification failed:',e.message);process.exitCode=1}
