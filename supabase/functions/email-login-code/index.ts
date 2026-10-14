import {createClient} from 'npm:@supabase/supabase-js@2.117.3'
import nodemailer from 'npm:nodemailer@10.1.1'

const url=Deno.env.get('SUPABASE_URL')!
const publicKey=Deno.env.get('SUPABASE_ANON_KEY')!
const serviceKey=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const admin=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}})
const origins=(Deno.env.get('APP_ORIGINS')||'http://127.0.0.1:5173,http://localhost:5173').split(',').map(s=>s.trim())
function headers(origin:string){return {'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS','Vary':'Origin','Cache-Control':'no-store'}}
function reply(origin:string,status:number,data:unknown){return Response.json(data,{status,headers:headers(origin)})}
async function digest(user:string,session:string,code:string,secret:string){
 const enc=new TextEncoder();const key=await crypto.subtle.importKey('raw',enc.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign'])
 const value=await crypto.subtle.sign('HMAC',key,enc.encode(`${user}:${session}:${code}`))
 return Array.from(new Uint8Array(value),v=>v.toString(16).padStart(2,'0')).join('')
}
function randomCode(){const values=new Uint32Array(1);do{crypto.getRandomValues(values)}while(values[0]>=4294960000);return String(values[0]%10000).padStart(4,'0')}
async function rpc(name:string,args:Record<string,unknown>){const r=await admin.rpc(name,args);if(r.error)throw new Error('Database verification failed');return r.data}
Deno.serve(async req=>{
 const origin=req.headers.get('origin')||''
 if(!origins.includes(origin))return reply('',403,{error:'This website origin is not allowed.'})
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers:headers(origin)})
 if(req.method!=='POST')return reply(origin,405,{error:'Use POST for this action.'})
 let transport:ReturnType<typeof nodemailer.createTransport>|undefined
 let stage='authenticate'
 try{
  const authorization=req.headers.get('authorization')||''
  const token=authorization.startsWith('Bearer ')?authorization.slice(7):''
  if(!token)return reply(origin,401,{error:'Sign in with your email and password first.'})
  const client=createClient(url,publicKey,{auth:{persistSession:false,autoRefreshToken:false}})
  const {data,error}=await client.auth.getUser(token)
  if(error||!data.user?.email)return reply(origin,401,{error:'Your sign-in session has expired.'})
  // getUser validated this token with Supabase Auth before its session claim is read.
  const encoded=token.split('.')[1].replace(/-/g,'+').replace(/_/g,'/')
  const claims=JSON.parse(atob(encoded.padEnd(Math.ceil(encoded.length/4)*4,'=')))
  const session=claims.session_id
  if(claims.sub!==data.user.id||!session||!/^[0-9a-f-]{36}$/i.test(session))return reply(origin,401,{error:'Invalid sign-in session.'})
  const payload=await req.json()
  const pepper=Deno.env.get('OTP_HMAC_SECRET')||''
  if(pepper.length<32)return reply(origin,503,{error:'Email verification is not configured yet. Please try again later.'})
  if(payload.action==='verify'){
   const code=String(payload.code||'')
   if(!/^\d{4}$/.test(code))return reply(origin,400,{error:'Enter the four digits from your email.'})
   const result=await rpc('tm_verify_email_code',{p_user:data.user.id,p_session:session,p_hash:await digest(data.user.id,session,code,pepper)})
   return reply(origin,result.verified?200:400,result)
  }
  if(payload.action!=='send')return reply(origin,400,{error:'Choose send or verify.'})
  const host=Deno.env.get('SMTP_HOST'),user=Deno.env.get('SMTP_USER'),rawPassword=Deno.env.get('SMTP_PASSWORD'),from=Deno.env.get('SMTP_FROM')
  const pass=host==='smtp.gmail.com'?rawPassword?.replace(/\s/g,''):rawPassword
  const port=Number(Deno.env.get('SMTP_PORT')||465)
  // Supabase blocks outbound SMTP on ports 25 and 587. Use implicit TLS on 465.
  if(!host||!user||!pass||!from||port!==465)return reply(origin,503,{error:'The email sender is not configured yet. Please try again later.'})
  const code=randomCode()
  stage='issue-code'
  const issue=await rpc('tm_issue_email_code',{p_user:data.user.id,p_session:session,p_hash:await digest(data.user.id,session,code,pepper)})
  if(!issue.ok)return reply(origin,429,{error:issue.error})
  transport=nodemailer.createTransport({host,port,secure:true,auth:{user,pass},tls:{minVersion:'TLSv1.2',rejectUnauthorized:true},connectionTimeout:10000,greetingTimeout:10000,socketTimeout:15000,pool:false})
  stage='send-email'
  const sent=await transport.sendMail({from,to:data.user.email,subject:'Tutormela verification code',text:`Tutormela verification code is ${code}.\n\nIt expires in 5 minutes. Do not share it with anyone.\nIf you did not request this code, you can ignore this email.`,html:`<div style="font-family:Arial,sans-serif;color:#263c38;max-width:480px;margin:auto;padding:24px"><h2>Tutormela</h2><p>Use this code to complete your sign-in:</p><p style="font-size:32px;font-weight:bold;letter-spacing:8px">${code}</p><p>Expires in 5 minutes. Do not share this code.</p><p>If you did not request it, you can ignore this email.</p></div>`})
  if(sent.rejected?.length||!sent.accepted?.length)throw Object.assign(new Error('SMTP did not accept the recipient'),{code:'ERECIPIENT'})
  stage='mark-delivered'
  await rpc('tm_mark_code_delivered',{p_user:data.user.id,p_session:session})
  return reply(origin,200,{sent:true,resendAfter:60,expiresAt:issue.expiresAt})
 }catch(error){
  // Only stable diagnostic categories: never log addresses, codes, tokens or SMTP responses.
  const category=String((error as {code?:string})?.code||'UNAVAILABLE').replace(/[^A-Z0-9_]/gi,'').slice(0,24)
  console.error('Email verification failed',{stage,category})
  return reply(origin,502,{error:'We could not complete email verification. Please try again later.'})
 }finally{transport?.close()}
})
