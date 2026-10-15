import {createClient} from 'npm:@supabase/supabase-js@2.117.3'
import nodemailer from 'npm:nodemailer@10.1.1'
const url=Deno.env.get('SUPABASE_URL')!
const admin=createClient(url,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}})
const origins=(Deno.env.get('APP_ORIGINS')||'http://127.0.0.1:5173,http://localhost:5173').split(',').map(s=>s.trim())
function headers(origin:string){return {'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS','Vary':'Origin','Cache-Control':'no-store'}}
const reply=(origin:string,status:number,data:unknown)=>Response.json(data,{status,headers:headers(origin)})
Deno.serve(async req=>{
 const origin=req.headers.get('origin')||''
 if(!origins.includes(origin))return reply('',403,{error:'Website origin not allowed.'})
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers:headers(origin)})
 if(req.method!=='POST')return reply(origin,405,{error:'Use POST.'})
 let transport:ReturnType<typeof nodemailer.createTransport>|undefined,job:Record<string,unknown>|undefined,studentId='',sending=false
 async function finish(status:string,error?:string,messageId?:string){if(!job)return;const r=await admin.rpc('tm_contact_delivery',{p_action:'finish',p_request:job.request_id,p_user:studentId,p_claim:job.claim_id,p_result:{status,error,messageId,from:Deno.env.get('SMTP_FROM')||Deno.env.get('SMTP_USER')}});if(r.error)throw new Error('Delivery status could not be stored')}
 try{
  const token=(req.headers.get('authorization')||'').replace(/^Bearer /,'')
  const client=createClient(url,Deno.env.get('SUPABASE_ANON_KEY')!,{global:{headers:{Authorization:'Bearer '+token}},auth:{persistSession:false,autoRefreshToken:false}})
  const auth=await client.auth.getUser(token)
  if(auth.error||!auth.data.user?.email)return reply(origin,401,{error:'Sign in before sending a contact request.'})
  studentId=auth.data.user.id
  const verified=await client.rpc('tm_auth_session_ready');if(verified.error||verified.data!==true)return reply(origin,403,{error:'Verify your sign-in first.'})
  const body=await req.json();if(!/^[0-9a-f-]{36}$/i.test(body.requestId||''))return reply(origin,400,{error:'Invalid contact request.'})
  const host=Deno.env.get('SMTP_HOST'),port=Number(Deno.env.get('SMTP_PORT')||465),user=Deno.env.get('SMTP_USER'),raw=Deno.env.get('SMTP_PASSWORD'),from=Deno.env.get('SMTP_FROM')||user
  if(!host||port!==465||!user||!raw||!from)return reply(origin,503,{sent:false,error:'Your request is saved. Email delivery is temporarily unavailable.'})
  const claimed=await admin.rpc('tm_contact_delivery',{p_action:'claim',p_request:body.requestId,p_user:studentId})
  if(claimed.error)return reply(origin,404,{error:'Contact request not found.'})
  if(!claimed.data.claimed)return reply(origin,200,{sent:claimed.data.status==='sent',status:claimed.data.status})
  job=claimed.data
  if(!job?.to_email||!job.reply_to_email){await finish('failed','registered_email_unavailable');return reply(origin,200,{sent:false,status:'failed'})}
  transport=nodemailer.createTransport({host,port,secure:true,auth:{user,pass:host==='smtp.gmail.com'?raw.replace(/\s/g,''):raw},tls:{minVersion:'TLSv1.2',rejectUnauthorized:true},connectionTimeout:10000,greetingTimeout:10000,socketTimeout:20000,pool:false})
  // Authenticate before send so connectivity failures are safe to retry.
  await transport.verify();sending=true
  const result=await transport.sendMail({from,to:String(job.to_email),replyTo:String(job.reply_to_email),subject:String(job.subject),text:String(job.text_body),messageId:`<tutormela-contact-${job.request_id}@${new URL(url).hostname}>`})
  if(!result.accepted?.length||result.rejected?.length){await finish('failed','recipient_rejected');return reply(origin,200,{sent:false,status:'failed'})}
  await finish('sent',undefined,result.messageId)
  return reply(origin,200,{sent:true,status:'sent'})
 }catch{
  if(job){try{await finish(sending?'unknown':'failed',sending?'delivery_confirmation_unavailable':'smtp_unavailable')}catch{/* Preserve sending/unknown; never resend an ambiguous SMTP submission automatically. */}}
  return reply(origin,200,{sent:false,status:sending?'unknown':'failed'})
 }finally{transport?.close()}
})
