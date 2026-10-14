import { passwordSignIn,isRealEmailAuth } from './email-auth.js'
import { createDemoSession } from './demo.js'
import { requireSupabase } from './supabase.js'
import { districts, subjects, classes, modes, days } from '../../server/catalog.js'
const fallbackCatalog={districts,subjects,classes,modes,days,demo:false}
const bucket='tm-profile-photos',photoCache=new Map()
let visitorToken
function visitor(){if(visitorToken)return visitorToken;try{visitorToken=localStorage.getItem('tm_visitor');if(!/^[0-9a-f-]{36}$/i.test(visitorToken||'')){visitorToken=crypto.randomUUID();localStorage.setItem('tm_visitor',visitorToken)}}catch{visitorToken=crypto.randomUUID()}return visitorToken}
const demoSession=import.meta.env.DEV?createDemoSession():null
let ready=false,publicProfiles=[]
const schemaMissing=e=>['PGRST205','PGRST202','42P01'].includes(e?.code)
function checked(result){if(result.error){if(schemaMissing(result.error))throw new Error('Database setup is pending. Run supabase/schema.sql in your Supabase SQL Editor, then refresh.');throw new Error(result.error.message||'The request could not be completed.')}return result.data}
const rpc=async(name,args)=>{const result=await requireSupabase().rpc(name,args);if(schemaMissing(result.error)&&['tm_feed','tm_save_shared_profile','tm_hide_feed_profile','tm_react_post','tm_record_view','tm_my_post_analytics','tm_edit_post'].includes(name))throw new Error('The tutor feed is being set up. Please try again later.');return checked(result)}
async function assertReady(){if(!ready){const r=await requireSupabase().from('tm_catalog').select('value').limit(1);checked(r);ready=true}}
async function getIdentity(){
 const s=requireSupabase()
 try{if(s.auth.initializePromise)await s.auth.initializePromise}catch{}
 try{
  const {data,error}=await s.auth.getUser()
  if(data?.user)return data.user
  if(error){
   const refreshed=await s.auth.refreshSession()
   if(refreshed.data?.user)return refreshed.data.user
  }
 }catch{}
 try{
  const sessionRes=await s.auth.getSession()
  if(sessionRes.data?.session?.user)return sessionRes.data.session.user
 }catch{}
 return null
}
async function signedPhoto(path){if(!path)return '';const cached=photoCache.get(path);if(cached&&cached.expires>Date.now())return cached.url;const r=await requireSupabase().storage.from(bucket).createSignedUrl(path,600);if(r.error)return '';const url=r.data.signedUrl;photoCache.set(path,{url,expires:Date.now()+480000});return url}
async function sessionReady(){try{return await rpc('tm_auth_session_ready')}catch{return true}}
async function emailCode(action,code){const r=await requireSupabase().functions.invoke('email-login-code',{body:{action,code}});if(r.error){let message='Email verification could not be completed. Try again.';try{const body=await r.error.context?.json();message=body?.error||message}catch{}throw new Error(message)}return r.data}
async function signupCode(action,body){
 const r=await requireSupabase().functions.invoke('email-signup-code',{body:{...body,action}})
 if(r.error){let details;try{details=await r.error.context?.json()}catch{}const error=new Error(details?.error||'Email verification could not be completed. Please try again.');if(details?.ticket)error.ticket=details.ticket;throw error}
 return r.data
}
async function beginEmailVerification(body){
 try{const r=await signupCode('start',body);if(!r.sent||!r.ticket)throw new Error('The verification email was not sent. Please try again.');return {verificationRequired:true,email:body.email.trim(),signupTicket:r.ticket}}
 catch(error){if(error.ticket)return {verificationRequired:true,email:body.email.trim(),signupTicket:error.ticket,deliveryError:error.message};throw error}
}
async function me(){const auth=await getIdentity();if(!auth||!await sessionReady())return null;const account=checked(await requireSupabase().from('tm_accounts').select('*').eq('id',auth.id).single());return {...account,email:auth.email,photo:await signedPhoto(account.photo_path)}}
async function profile(row){if(!row)return null;return {...row,photo:await signedPhoto(row.photo_path),aboutEn:row.about_en,aboutBn:row.about_bn,sample:false,created:row.created_at,reason:''}}
async function uploadPhoto(dataUrl,userId){
 if(!dataUrl?.startsWith('data:image/'))return null
 const blob=await (await fetch(dataUrl)).blob();if(!['image/jpeg','image/png','image/webp'].includes(blob.type)||blob.size>2097152)throw new Error('Choose a JPEG, PNG or WebP photo under 2 MB.')
 const bytes=new Uint8Array(await blob.slice(0,12).arrayBuffer());const valid=(bytes[0]===255&&bytes[1]===216)||(bytes[0]===137&&bytes[1]===80&&bytes[2]===78&&bytes[3]===71)||(String.fromCharCode(...bytes.slice(0,4))==='RIFF'&&String.fromCharCode(...bytes.slice(8,12))==='WEBP');if(!valid)throw new Error('The photo is not a supported image.')
 const ext=blob.type==='image/jpeg'?'jpg':blob.type.split('/')[1];const path=`${userId}/${crypto.randomUUID()}.${ext}`
 checked(await requireSupabase().storage.from(bucket).upload(path,blob,{contentType:blob.type,upsert:false,cacheControl:'600'}));return path
}
async function withPhoto(body,save){const auth=await getIdentity();if(!auth)throw new Error('Please sign in.');let uploaded;try{uploaded=await uploadPhoto(body.photo,auth.id);return await save({...body,photo_path:uploaded||body.photo_path||null})}catch(e){if(uploaded)await requireSupabase().storage.from(bucket).remove([uploaded]);throw e}}
export async function readDevicePhoto(file){
 if(!file||!['image/jpeg','image/png','image/webp'].includes(file.type)||file.size>2097152)throw new Error('Choose a JPEG, PNG or WebP photo under 2 MB.')
 const bitmap=await createImageBitmap(file);if(bitmap.width>8000||bitmap.height>8000){bitmap.close();throw new Error('The image dimensions are too large. Choose a smaller photo.')}
 const scale=Math.min(1,900/Math.max(bitmap.width,bitmap.height));const canvas=document.createElement('canvas');canvas.width=Math.round(bitmap.width*scale);canvas.height=Math.round(bitmap.height*scale);canvas.getContext('2d').drawImage(bitmap,0,0,canvas.width,canvas.height);bitmap.close()
 // Re-encode the image to remove location/device EXIF metadata before upload.
 return canvas.toDataURL('image/webp',.88)
}
export async function api(path,method='GET',body){
 // Explicit real authentication must leave a restored local demo session first.
 if(demoSession?.active&&isRealEmailAuth(path))demoSession.request('/auth/logout','POST',{})

 if(demoSession?.handles(path,method)){
  const result=demoSession.request(path,method,body);
  if(path.startsWith('/feed')&&method==='GET'&&Array.isArray(result)){
   if(result.length>0)return result
   try{const params=new URLSearchParams(path.split('?')[1]||'');const rows=await rpc('tm_feed',{p_before:params.get('before')||null,p_before_id:params.get('id')||null});return Promise.all(rows.map(async row=>({...row,profile:await profile(row.profile)})))}catch{return result}
  }
  return path==='/saved'&&method==='GET'?publicProfiles.filter(p=>result.includes(p.id)):result
 }
 const s=requireSupabase()
 if(path==='/catalog'){
  const result=await s.from('tm_catalog').select('*').order('sort_order')
  if(result.error&&schemaMissing(result.error))return {...fallbackCatalog,setupRequired:true}
  const rows=checked(result);ready=true;const c={demo:false,setupRequired:false};for(const category of ['districts','subjects','classes','modes','days'])c[category]=rows.filter(r=>r.category===category).map(r=>r.value);return c
 }
 if(path==='/profiles'&&method==='GET'){let r=await s.from('tm_tutor_profiles').select('*').or('status.eq.approved,and(status.eq.pending,feed_visible.eq.true)').order('created_at',{ascending:false});if(r.error?.code==='42703')r=await s.from('tm_tutor_profiles').select('*').eq('status','approved').order('created_at',{ascending:false});if(r.error&&schemaMissing(r.error))return [];publicProfiles=await Promise.all(checked(r).map(profile));return [...publicProfiles,...(demoSession?.publicProfiles||[])]}
 if(path.startsWith('/feed')&&method==='GET'){const params=new URLSearchParams(path.split('?')[1]||'');let dbRows=[];try{const rows=await rpc('tm_feed',{p_before:params.get('before')||null,p_before_id:params.get('id')||null});dbRows=await Promise.all(rows.map(async row=>({...row,profile:await profile(row.profile)})))}catch(e){if(!demoSession?.hasPosts)throw e}const demoRows=demoSession?.getFeedPosts(params.get('before'),params.get('id'))||[];return [...dbRows,...demoRows.filter(dp=>!dbRows.some(r=>r.id===dp.id))].sort((a,b)=>b.created_at.localeCompare(a.created_at)||b.id.localeCompare(a.id)).slice(0,20)}
 if(/^\/feed\/[^/]+\/reaction$/.test(path)){return {count:await rpc('tm_react_post',{p_post:path.split('/')[2],p_reacted:body.reacted})}}
 if(path==='/views'){await rpc('tm_record_view',{p_kind:body.kind,p_target:body.target,p_visitor:visitor()});return {ok:true}}
 if(path==='/analytics')return rpc('tm_my_post_analytics')
 if(path==='/profile/hide'){await rpc('tm_hide_feed_profile');return {ok:true}}
 if(path==='/me'){try{await assertReady()}catch{}const auth=await getIdentity();if(!auth)return {user:null};if(!await sessionReady())return {user:null,verificationRequired:true,email:auth.email};return {user:await me()}}
 if(path==='/auth/login'){await assertReady();return passwordSignIn({auth:s.auth,codeEnabled:()=>rpc('tm_email_code_enabled'),sendCode:()=>emailCode('send'),confirmEmail:credentials=>beginEmailVerification({...credentials,intent:'confirm'}),currentUser:me},body)}
 if(path==='/auth/register'){await assertReady();return beginEmailVerification({...body,intent:'register'})}
 if(path==='/auth/social'){if(!['google','facebook'].includes(body.provider))throw new Error('Choose Google or Facebook.');const response=await fetch(import.meta.env.VITE_SUPABASE_URL+'/auth/v1/settings',{headers:{apikey:import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY}});if(!response.ok)throw new Error('Sign-in is temporarily unavailable.');const settings=await response.json();if(!settings.external?.[body.provider])throw new Error(`${body.provider==='google'?'Google':'Facebook'} sign-in is currently unavailable. Please use email sign-in.`);sessionStorage.setItem('tm_oauth_role',body.role||'student');checked(await s.auth.signInWithOAuth({provider:body.provider,options:{redirectTo:window.location.origin+'/#/dashboard',...(body.provider==='facebook'?{scopes:'email'}:{})}}));return {redirecting:true}}
 if(path==='/auth/code/send')return body?.signupTicket?signupCode('resend',{ticket:body.signupTicket}):emailCode('send')
 if(path==='/auth/code/verify'){const r=body.signupTicket?await signupCode('verify',{ticket:body.signupTicket,code:body.code}):await emailCode('verify',body.code);if(!r.verified)throw new Error(r.error||'This code could not be verified.');if(r.session)checked(await s.auth.setSession(r.session));return {user:await me()}}
 if(path==='/account/role'){await rpc('tm_choose_account_role',{p_role:body.role});sessionStorage.removeItem('tm_oauth_role');return {user:await me()}}
 if(path.startsWith('/statuses?')){const params=new URLSearchParams(path.split('?')[1]);let query=s.from('tm_tutor_statuses').select('*').eq('profile_id',params.get('profile')).order('created_at',{ascending:false}).limit(30);if(params.get('owner')!=='1')query=query.is('withdrawn_at',null);return checked(await query)}
 if(path==='/statuses'&&method==='POST'){await rpc('tm_post_tutor_status',{p_body:body.body,p_consent:body.consent});return {ok:true}}
 if(path.startsWith('/statuses/')&&method==='PUT'){await rpc('tm_edit_post',{p_id:path.split('/').pop(),p_body:body.body});return {ok:true}}
 if(path.startsWith('/statuses/')&&method==='PATCH'){await rpc('tm_set_status_visibility',{p_id:path.split('/').pop(),p_visible:body.visible});return {ok:true}}
 if(path==='/auth/logout'){checked(await s.auth.signOut());photoCache.clear();return {ok:true}}
 if(path==='/auth/reset'){checked(await s.auth.resetPasswordForEmail(body.email,{redirectTo:window.location.origin+'/#/password-reset'}));return {ok:true}}
 if(path==='/account/email'){if(!await sessionReady())throw new Error('Verify your sign-in before changing login details.');checked(await s.auth.updateUser({email:body.email}));return {confirmationRequired:true}}
 if(path==='/account/password'){if(!await sessionReady())throw new Error('Verify your sign-in before changing login details.');checked(await s.auth.updateUser({password:body.password}));return {ok:true}}
 if(path==='/auth/password'){checked(await s.auth.updateUser({password:body.password}));return {ok:true}}
 if(path==='/account'&&method==='PUT')return withPhoto(body,async b=>{await rpc('tm_update_account',{p_body:b});return {user:await me()}})
 if(path==='/preferences'&&method==='PUT'){await rpc('tm_save_preferences',{p_preferences:body});return {ok:true}}
 if(path==='/profile'){
  const auth=await getIdentity();if(!auth)throw new Error('Please sign in.');
  if(method==='GET'){const row=checked(await s.from('tm_tutor_profiles').select('*').eq('user_id',auth.id).maybeSingle());const p=await profile(row);if(p&&p.status==='rejected'){const reviews=checked(await s.from('tm_profile_reviews').select('reason').eq('profile_id',p.id).order('created_at',{ascending:false}).limit(1));p.reason=reviews[0]?.reason||''}return p}
  if(method==='PUT')return withPhoto(body,async b=>{const saved=await rpc('tm_save_shared_profile',{p_body:b,p_publish:!body.draft,p_consent:!!body.consent});return profile(Array.isArray(saved)?saved[0]:saved)})
 }
 if(path==='/saved'){
  const auth=await getIdentity();if(!auth)throw new Error('Please sign in.');
  if(method==='GET'){const rows=checked(await s.from('tm_saved_tutors').select('profile_id, tm_tutor_profiles(*)'));return Promise.all(rows.filter(r=>r.tm_tutor_profiles?.status==='approved').map(r=>profile(r.tm_tutor_profiles)))}
  if(method==='POST'){checked(await s.from('tm_saved_tutors').upsert({user_id:auth.id,profile_id:body.profileId},{onConflict:'user_id,profile_id',ignoreDuplicates:true}));return {ok:true}}
  if(method==='DELETE'){checked(await s.from('tm_saved_tutors').delete().eq('user_id',auth.id).eq('profile_id',body.profileId));return {ok:true}}
 }
 if(path==='/requests'){
  if(method==='POST'){await rpc('tm_send_request',{p_body:body});return {ok:true}}
  const rows=await rpc('tm_my_requests');return rows.map(r=>({...r,studentName:r.student_name,className:r.class_name,tutorName:r.tutor_name,created:r.created_at}))
 }
 if(/^\/requests\//.test(path)){await rpc('tm_update_request',{p_id:path.split('/').pop(),p_status:body.status});return {ok:true}}
 if(path==='/admin/profiles'){const rows=checked(await s.from('tm_tutor_profiles').select('*').neq('status','draft').order('updated_at',{ascending:false}));return Promise.all(rows.map(profile))}
 if(/^\/admin\/profiles\//.test(path)){await rpc('tm_review_tutor',{p_id:path.split('/').pop(),p_status:body.status,p_reason:body.reason||''});return {ok:true}}
 throw new Error('This action is not available.')
}
