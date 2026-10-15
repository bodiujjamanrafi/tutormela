import {resolveAccountRole} from './account-role.js'
import {matchesTutorPost,sortTutorPosts} from './tutor-posts.js'
import { passwordSignIn } from './email-auth.js'
import { requireSupabase } from './supabase.js'
import { divisions } from '../assets/maps/geography.js'
import { districts, subjects, classes, modes, days } from '../../server/catalog.js'
const fallbackCatalog={districts,subjects,classes,modes,days,demo:false}
const bucket='tm-profile-photos',photoCache=new Map()
let visitorToken
function visitor(){if(visitorToken)return visitorToken;try{visitorToken=localStorage.getItem('tm_visitor');if(!/^[0-9a-f-]{36}$/i.test(visitorToken||'')){visitorToken=crypto.randomUUID();localStorage.setItem('tm_visitor',visitorToken)}}catch{visitorToken=crypto.randomUUID()}return visitorToken}
let ready=false,publicProfiles=[]
const schemaMissing=e=>['PGRST205','PGRST202','42P01'].includes(e?.code)
function checked(result){if(result.error){if(schemaMissing(result.error))throw new Error('Database setup is pending. Run supabase/schema.sql in your Supabase SQL Editor, then refresh.');throw new Error(result.error.message||'The request could not be completed.')}return result.data}
const rpc=async(name,args)=>{const result=await requireSupabase().rpc(name,args);if(schemaMissing(result.error)&&['tm_post_quota','tm_register_plan_interest'].includes(name))throw new Error('Posting plans are being set up. Please try again later.');if(schemaMissing(result.error)&&name==='tm_admin_posts')throw new Error('Feed moderation is not available yet. Please finish the database update.');if(schemaMissing(result.error)&&['tm_feed','tm_save_shared_profile','tm_hide_feed_profile','tm_react_post','tm_record_view','tm_my_post_analytics','tm_edit_post'].includes(name))throw new Error('The tutor feed is being set up. Please try again later.');return checked(result)}
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
async function sessionReady(){return rpc('tm_auth_session_ready')}
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
function googleAccountPhoto(auth){
 const identity=auth.identities?.find(item=>item.provider==='google')
 try{const url=new URL(identity?.identity_data?.picture||identity?.identity_data?.avatar_url||'');return url.protocol==='https:'&&(url.hostname==='googleusercontent.com'||url.hostname.endsWith('.googleusercontent.com'))?url.href:''}catch{return ''}
}
async function accountForRole(requestedRole){return resolveAccountRole({account:await me(),requestedRole,chooseRole:role=>rpc('tm_choose_account_role',{p_role:role}),reload:me})}
async function me(){const auth=await getIdentity();if(!auth||!await sessionReady())return null;const account=checked(await requireSupabase().from('tm_accounts').select('*').eq('id',auth.id).single());return {...account,email:auth.email,photo:await signedPhoto(account.photo_path)||googleAccountPhoto(auth)}}
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
 const s=requireSupabase()
 if(path==='/payments/checkout'){const r=await s.functions.invoke('bkash-checkout',{body:{action:'start',plan:body.plan,returnOrigin:window.location.origin}});if(r.error){let detail;try{detail=await r.error.context?.json()}catch{}throw new Error(detail?.error||'bKash checkout is not connected yet. No payment has been taken.')}return r.data}
 if(path==='/payments/status'){const r=await s.functions.invoke('bkash-checkout',{body:{action:'status',order:body.order}});if(r.error)throw new Error('Payment status could not be checked. Please try again.');return r.data}
 if(path==='/identity'&&method==='PUT')return withPhoto(body,async b=>{const current=await me();if(current?.role!=='tutor')throw new Error('Tutor account required.');await rpc('tm_save_identity',{p_body:{...b,photo:undefined}});return {user:await me()}})
 if(path==='/plans')return checked(await s.from('tm_plans').select('*').eq('enabled',true).order('sort_order'))
 if(path==='/plans/interest'&&method==='POST')return rpc('tm_register_plan_interest',{p_plan:body.plan})
 if(path==='/posting-allowance')return rpc('tm_teaching_quota')
 if(path==='/browse-posts'){
  const filters={...body.filters};if(filters.division)filters.districts=divisions.find(d=>d.name===filters.division)?.districts||[]
  const request=await s.rpc('tm_browse_teaching_posts',{p_filters:filters,p_sort:body.sort||'recommended',p_page:body.page||1})
  if(!request.error){const result=request.data;return {...result,items:await Promise.all(result.items.map(async row=>({...row,profile:await profile(row.profile)})))}}
  if(!schemaMissing(request.error))checked(request)
  // Preserve existing database records while the additive card-feed SQL is awaiting application.
  let rows=[],cursor=null
  while(true){const next=await rpc('tm_feed',{p_before:cursor?.created_at||null,p_before_id:cursor?.id||null});rows.push(...next);const last=next.at(-1);if(next.length<20||!last||last.id===cursor?.id)break;cursor=last}
  const converted=await Promise.all(rows.map(async row=>({...row,profile:await profile(row.profile),postViews:null,profileViews:null})))
  let analytics;try{analytics=await rpc('tm_my_post_analytics')}catch{}
  for(const post of converted){const own=analytics?.posts.find(p=>p.id===post.id);if(own){post.postViews=own.views;post.profileViews=analytics.profileViews}}
  const posted=new Set(converted.map(p=>p.profile.id))
  const profiles=publicProfiles.length?publicProfiles:await api('/profiles')
  for(const p of profiles)if(!posted.has(p.id))converted.push({id:null,profile:p,kind:'identity',body:p.aboutEn||p.aboutBn||'Teaching profile',created_at:p.created_at||p.created,owner:false,reactions:0,reacted:false,postViews:null,profileViews:null})
  const filtered=sortTutorPosts(converted.filter(p=>matchesTutorPost(p,filters)),body.sort),page=Math.max(1,Number(body.page)||1)
  return {items:filtered.slice((page-1)*6,page*6),total:filtered.length,page,pageSize:6,setupPending:true}
 }
 if(path==='/workspace'){
  const result=await s.rpc('tm_workspace_posts');let data;
  if(schemaMissing(result.error)){const analytics=await rpc('tm_my_post_analytics'),own=await api('/profile');data={...analytics,drafts:[],setupPending:true,posts:analytics.posts.map(post=>({...post,details:post.kind==='identity'?own:null}))}}else data=checked(result);
  return {...data,posts:await Promise.all(data.posts.map(async post=>({...post,details:post.details?await profile(post.details):null}))),drafts:await Promise.all(data.drafts.map(async draft=>({...draft,details:{...draft.details,photo:await signedPhoto(draft.details.photo_path)}})))}
 }
 if(path==='/teaching-posts'&&method==='POST')return withPhoto(body,async b=>rpc('tm_save_teaching_post',{p_id:body.postId||null,p_body:{...b,photo:undefined},p_publish:!body.draft,p_consent:!!body.consent}))
 if(path.startsWith('/public-identity/')){const identity=await rpc('tm_public_identity',{p_profile:path.split('/').pop()});return identity?{...identity,photo:await signedPhoto(identity.photo_path)}:null}
 if(path==='/documents/download'){const response=await s.storage.from('tm-tutor-documents').download(body.path);const blob=checked(response),url=URL.createObjectURL(blob),anchor=document.createElement('a');anchor.href=url;anchor.download=(String(body.title||'Tutor document').replace(/[^\p{L}\p{N} ._-]/gu,'').slice(0,100)||'Tutor document')+'.pdf';document.body.append(anchor);anchor.click();anchor.remove();setTimeout(()=>URL.revokeObjectURL(url),10000);return {ok:true}}
 if(path==='/documents'&&method==='POST'){
  const auth=await getIdentity();if(!auth)throw new Error('Sign in to upload a document.');const file=body.file;
  if(!file||file.type!=='application/pdf'||file.size>5242880||file.size<5||new TextDecoder().decode(await file.slice(0,5).arrayBuffer())!=='%PDF-')throw new Error('Choose a valid PDF file up to 5 MB.');
  const path=auth.id+'/'+crypto.randomUUID()+'.pdf';checked(await s.storage.from('tm-tutor-documents').upload(path,file,{contentType:'application/pdf',upsert:false}));
  try{return await rpc('tm_document_action',{p_action:'add',p_body:{path,title:body.title,kind:body.kind,size:file.size,shared:!!body.shared}})}catch(e){await s.storage.from('tm-tutor-documents').remove([path]);throw e}
 }
 if(path==='/documents'||path.startsWith('/documents?')){
  let rows;if(path.includes('?')){const result=await s.rpc('tm_list_documents',{p_profile:new URLSearchParams(path.split('?')[1]).get('profile')});rows=schemaMissing(result.error)?[]:checked(result)}else{const auth=await getIdentity();if(!auth)throw new Error('Please sign in.');rows=checked(await s.from('tm_tutor_documents').select('*').eq('user_id',auth.id).order('created_at',{ascending:false}))}
  return Promise.all(rows.map(async doc=>{const result=await s.storage.from('tm-tutor-documents').createSignedUrl(doc.path,120);checked(result);return {...doc,url:result.data.signedUrl}}))
 }
 if(/^\/documents\/[^/]+$/.test(path)){const doc=await rpc('tm_document_action',{p_action:method==='DELETE'?'remove':'share',p_body:{id:path.split('/').pop(),shared:body?.shared}});if(method==='DELETE')checked(await s.storage.from('tm-tutor-documents').remove([doc.path]));return {ok:true}}
 if(path==='/catalog'){
  const result=await s.from('tm_catalog').select('*').order('sort_order')
  if(result.error&&schemaMissing(result.error))return {...fallbackCatalog,setupRequired:true}
  const rows=checked(result);ready=true;const c={demo:false,setupRequired:false};for(const category of ['districts','subjects','classes','modes','days'])c[category]=rows.filter(r=>r.category===category).map(r=>r.value);return c
 }
 if(path==='/profiles'&&method==='GET'){let r=await s.from('tm_tutor_profiles').select('*').or('status.eq.approved,and(status.eq.pending,feed_visible.eq.true)').order('created_at',{ascending:false});if(r.error?.code==='42703')r=await s.from('tm_tutor_profiles').select('*').eq('status','approved').order('created_at',{ascending:false});if(r.error&&schemaMissing(r.error))return [];publicProfiles=await Promise.all(checked(r).map(profile));return publicProfiles}
 if(path.startsWith('/feed')&&method==='GET'){const params=new URLSearchParams(path.split('?')[1]||'');const rows=await rpc('tm_feed',{p_before:params.get('before')||null,p_before_id:params.get('id')||null});return Promise.all(rows.map(async row=>({...row,profile:await profile(row.profile)})))}
 if(/^\/feed\/[^/]+\/reaction$/.test(path)){return {count:await rpc('tm_react_post',{p_post:path.split('/')[2],p_reacted:body.reacted})}}
 if(path==='/views'){await rpc('tm_record_view',{p_kind:body.kind,p_target:body.target,p_visitor:visitor()});return {ok:true}}
 if(path==='/analytics')return rpc('tm_my_post_analytics')
 if(path==='/profile/hide'){await rpc('tm_hide_feed_profile');return {ok:true}}
 if(path==='/me'){try{await assertReady()}catch{}const auth=await getIdentity();if(!auth)return {user:null};if(!await sessionReady())return {user:null,verificationRequired:true,email:auth.email};return {user:await me()}}
 if(path==='/auth/login'){await assertReady();return passwordSignIn({auth:s.auth,codeEnabled:()=>rpc('tm_email_code_enabled'),sendCode:()=>emailCode('send'),confirmEmail:credentials=>beginEmailVerification({...credentials,intent:'confirm'}),currentUser:()=>accountForRole(body.role)},body)}
 if(path==='/auth/register'){await assertReady();return beginEmailVerification({...body,intent:'register'})}
 if(path==='/auth/social'&&body.provider==='google'){
  const [{googleCredential,clearFirebaseSignIn},{firebaseGoogleSession}]=await Promise.all([import('./firebase.js'),import('./google-auth-flow.js')]);
  const authenticated=await firebaseGoogleSession({checkProvider:async()=>{const response=await fetch(import.meta.env.VITE_SUPABASE_URL+'/auth/v1/settings',{headers:{apikey:import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY}});if(!response.ok)throw new Error('Sign-in is temporarily unavailable. Please try again.');const settings=await response.json();if(settings.external?.google!==true)throw new Error('Google sign-in is not active for Tutormela yet. Please use email sign-in until Google is enabled.')},getCredential:googleCredential,exchange:credentials=>s.auth.signInWithIdToken(credentials),verifyUser:token=>s.auth.getUser(token),clear:clearFirebaseSignIn});
  let account=await me();if(!account||account.id!==authenticated.user.id)throw new Error('Your Google account could not be matched to your website account. Please sign in again.');
  account=await resolveAccountRole({account,requestedRole:body.role,chooseRole:role=>rpc('tm_choose_account_role',{p_role:role}),reload:me})
  if(!account||account.id!==authenticated.user.id)throw new Error('Your sign-in account changed. Please sign in again.');sessionStorage.removeItem('tm_oauth_role');return {user:account}
 }
 if(path==='/auth/social'){if(!['google','facebook'].includes(body.provider))throw new Error('Choose Google or Facebook.');const response=await fetch(import.meta.env.VITE_SUPABASE_URL+'/auth/v1/settings',{headers:{apikey:import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY}});if(!response.ok)throw new Error('Sign-in is temporarily unavailable.');const settings=await response.json();if(!settings.external?.[body.provider])throw new Error(`${body.provider==='google'?'Google':'Facebook'} sign-in is currently unavailable. Please use email sign-in.`);sessionStorage.setItem('tm_oauth_role',body.role||'student');checked(await s.auth.signInWithOAuth({provider:body.provider,options:{redirectTo:window.location.origin+'/#/dashboard',...(body.provider==='facebook'?{scopes:'email'}:{})}}));return {redirecting:true}}
 if(path==='/auth/code/send')return body?.signupTicket?signupCode('resend',{ticket:body.signupTicket}):emailCode('send')
 if(path==='/auth/code/verify'){const r=body.signupTicket?await signupCode('verify',{ticket:body.signupTicket,code:body.code}):await emailCode('verify',body.code);if(!r.verified)throw new Error(r.error||'This code could not be verified.');if(r.session)checked(await s.auth.setSession(r.session));return {user:await accountForRole(body.role)}}
 if(path==='/account/role'){await rpc('tm_choose_account_role',{p_role:body.role});sessionStorage.removeItem('tm_oauth_role');return {user:await me()}}
 if(path.startsWith('/statuses?')){const params=new URLSearchParams(path.split('?')[1]);let query=s.from('tm_tutor_statuses').select('*').eq('profile_id',params.get('profile')).order('created_at',{ascending:false}).limit(30);if(params.get('owner')!=='1')query=query.is('withdrawn_at',null);return checked(await query)}
 if(path==='/statuses'&&method==='POST'){const quota=await rpc('tm_post_quota');if(!quota.canPost)throw new Error('Your posting allowance is used. View plans to publish more.');await rpc('tm_post_tutor_status',{p_body:body.body,p_consent:body.consent});return {ok:true}}
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
  if(method==='PUT')return withPhoto(body,async b=>{if(!body.draft){const quota=await rpc('tm_post_quota');if(!quota.canPost){const auth=await getIdentity();const existing=checked(await s.from('tm_tutor_statuses').select('id').eq('user_id',auth.id).eq('kind','identity').maybeSingle());if(!existing)throw new Error('Your posting allowance is used. View plans to publish more.')}}const saved=await rpc('tm_save_shared_profile',{p_body:b,p_publish:!body.draft,p_consent:!!body.consent});return profile(Array.isArray(saved)?saved[0]:saved)})
 }
 if(path==='/tutor-page'){
  if(!/^[0-9a-f-]{36}$/i.test(body.profileId)||body.postId&&!/^[0-9a-f-]{36}$/i.test(body.postId))throw new Error('This profile link is invalid.');
  const result=await s.rpc('tm_tutor_page',{p_profile:body.profileId,p_post:body.postId||null});
  if(!schemaMissing(result.error))return profile(checked(result));
  // Exact-ID fallback while the additive delivery/shortlist update is being applied.
  const current=checked(await s.from('tm_tutor_profiles').select('*').eq('id',body.profileId).maybeSingle());if(!current)return null;
  if(body.postId){const post=checked(await s.from('tm_tutor_statuses').select('*').eq('id',body.postId).eq('profile_id',body.profileId).is('withdrawn_at',null).maybeSingle());if(!post)return null;return profile({...current,...post.details,id:current.id,status:current.status,postId:post.id})}
  return profile(current)
 }
 if(path==='/saved'){
  const auth=await getIdentity();if(!auth)throw new Error('Please sign in.');
  if(method==='GET'){const result=await s.rpc('tm_my_saved_tutors');if(!schemaMissing(result.error))return Promise.all(checked(result).map(profile));const rows=checked(await s.from('tm_saved_tutors').select('profile_id, tm_tutor_profiles(*)').eq('user_id',auth.id));return Promise.all(rows.map(r=>profile(r.tm_tutor_profiles||{id:r.profile_id,name:'Saved tutor',subjects:[],classes:[],modes:[],days:[],areas:'',fee:0,unavailable:true})))}
  if(method==='POST'){const result=await s.rpc('tm_save_favourite',{p_profile:body.profileId,p_post:body.postId||null});if(schemaMissing(result.error))checked(await s.from('tm_saved_tutors').upsert({user_id:auth.id,profile_id:body.profileId},{onConflict:'user_id,profile_id',ignoreDuplicates:true}));else checked(result);return {ok:true}}
  if(method==='DELETE'){checked(await s.from('tm_saved_tutors').delete().eq('user_id',auth.id).eq('profile_id',body.profileId));return {ok:true}}
 }
 if(path==='/requests'){
  if(method==='POST'){const id=await rpc('tm_send_request',{p_body:body});let result;try{const response=await s.functions.invoke('contact-request-email',{body:{requestId:id}});if(!response.error)result=response.data}catch{}return {ok:true,id,emailSent:result?.sent===true}}
  const rows=await rpc('tm_my_requests');return rows.map(r=>({...r,studentName:r.student_name,className:r.class_name,tutorName:r.tutor_name,created:r.created_at}))
 }
 if(path==='/requests/email'){const response=await s.functions.invoke('contact-request-email',{body:{requestId:body.id}});if(response.error)throw new Error('Email delivery could not be confirmed. Your request is still saved.');return response.data}
 if(/^\/requests\//.test(path)){await rpc('tm_update_request',{p_id:path.split('/').pop(),p_status:body.status});return {ok:true}}
 if(path.startsWith('/admin/posts')&&method==='GET'){const params=new URLSearchParams(path.split('?')[1]||'');return rpc('tm_admin_posts',{p_before:params.get('before')||null,p_before_id:params.get('id')||null})}
 if(/^\/admin\/posts\/[^/]+$/.test(path)&&method==='PATCH'){await rpc('tm_set_status_visibility',{p_id:path.split('/').pop(),p_visible:body.visible});return {ok:true}}
 if(path==='/auth/demo')throw new Error('Create a verified account to save your posts in the database.')
 if(path==='/admin/profiles'){const rows=checked(await s.from('tm_tutor_profiles').select('*').neq('status','draft').order('updated_at',{ascending:false}));return Promise.all(rows.map(profile))}
 if(/^\/admin\/profiles\//.test(path)){await rpc('tm_review_tutor',{p_id:path.split('/').pop(),p_status:body.status,p_reason:body.reason||''});return {ok:true}}
 throw new Error('This action is not available.')
}
