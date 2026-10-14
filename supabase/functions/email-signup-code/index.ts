import {createClient} from 'npm:@supabase/supabase-js@2.117.3'
import nodemailer from 'npm:nodemailer@10.1.1'
import {createVerifiedEmailSession,checkInitialPassword} from './verified-session.js'
const url=Deno.env.get('SUPABASE_URL')!, publicKey=Deno.env.get('SUPABASE_ANON_KEY')!
const admin=createClient(url,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}})
const origins=(Deno.env.get('APP_ORIGINS')||'http://127.0.0.1:5173,http://localhost:5173').split(',').map(s=>s.trim())
const secret=Deno.env.get('OTP_HMAC_SECRET')||''
const headers=(origin:string)=>({'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS','Vary':'Origin','Cache-Control':'no-store'})
const reply=(origin:string,status:number,data:unknown)=>Response.json(data,{status,headers:headers(origin)})
async function hash(value:string){const enc=new TextEncoder(),key=await crypto.subtle.importKey('raw',enc.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);return Array.from(new Uint8Array(await crypto.subtle.sign('HMAC',key,enc.encode(value))),v=>v.toString(16).padStart(2,'0')).join('')}
function randomCode(){const n=new Uint32Array(1);do{crypto.getRandomValues(n)}while(n[0]>=4294960000);return String(n[0]%10000).padStart(4,'0')}
async function operation(action:string,body:Record<string,unknown>){const {data,error}=await admin.rpc('tm_signup_email',{p_action:action,p_body:body});if(error)throw Object.assign(new Error('Verification database unavailable'),{code:['PGRST202','42883'].includes(error.code)?'ESETUP':'EDATABASE'});return data}
async function recipient(id:string){const {data,error}=await admin.auth.admin.getUserById(id);if(error||!data.user?.email)throw new Error('Account unavailable');return data.user}
Deno.serve(async req=>{
 const origin=req.headers.get('origin')||''
 if(!origins.includes(origin))return reply('',403,{error:'This website origin is not allowed.'})
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers:headers(origin)})
 if(req.method!=='POST')return reply(origin,405,{error:'Use POST for this action.'})
 let transport:ReturnType<typeof nodemailer.createTransport>|undefined,ticket='',stage='validate'
 try{
  if(secret.length<32)return reply(origin,503,{error:'Email verification is temporarily unavailable.'})
  if(Number(req.headers.get('content-length')||0)>8192)return reply(origin,413,{error:'The request is too large.'})
  const rawBody=await req.text();if(rawBody.length>8192)return reply(origin,413,{error:'The request is too large.'});const payload=JSON.parse(rawBody)
  if(!['start','resend','verify'].includes(payload.action))return reply(origin,400,{error:'Choose a verification action.'})
  let ticketHash='',account
  if(payload.action!=='start'){
   ticket=String(payload.ticket||'')
   if(!/^[0-9a-f]{64}$/.test(ticket))return reply(origin,400,{error:'Please enter your email and password again.'})
   ticketHash=await hash('ticket:'+ticket)
  }
  if(payload.action==='verify'){
   const code=String(payload.code||'')
   if(!/^\d{4}$/.test(code))return reply(origin,400,{error:'Enter the four digits from your email.'})
   const verified=await operation('verify',{ticket_hash:ticketHash,code_hash:await hash('code:'+ticket+':'+code)})
   if(!verified.ok)return reply(origin,400,{error:verified.error})
   account=await recipient(verified.user_id)
   if(await hash('email:'+account.email!.toLowerCase())!==verified.email_hash)return reply(origin,400,{error:'Your email changed. Please sign in again.'})
   stage='confirm-email'
   // A delivered, single-use code proves ownership. Never change the account's password or role.
   const confirmed=await admin.auth.admin.updateUserById(account.id,{email_confirm:true})
   if(confirmed.error)throw new Error('Email confirmation unavailable')
   const client=createClient(url,publicKey,{auth:{persistSession:false,autoRefreshToken:false}})
   stage='create-session'
   const session=await createVerifiedEmailSession(admin.auth.admin,client.auth,account)
   // This token was just issued by Supabase Auth; bind the verification to its own user/session.
   const encoded=session.access_token.split('.')[1].replace(/-/g,'+').replace(/_/g,'/')
   const claims=JSON.parse(atob(encoded.padEnd(Math.ceil(encoded.length/4)*4,'=')))
   if(claims.sub!==account.id||!claims.session_id)throw new Error('Invalid sign-in session')
   const completed=await operation('complete',{ticket_hash:ticketHash,session_id:claims.session_id})
   if(!completed.ok)return reply(origin,400,{error:completed.error})
   return reply(origin,200,{verified:true,session:{access_token:session.access_token,refresh_token:session.refresh_token}})
  }
  let email=String(payload.email||'').trim().toLowerCase()
  if(payload.action==='resend'){
   const challenge=await operation('recipient',{ticket_hash:ticketHash})
   if(!challenge.ok)return reply(origin,400,{error:challenge.error})
   account=await recipient(challenge.user_id);email=account.email!.toLowerCase();if(await hash('email:'+email)!==challenge.email_hash)return reply(origin,400,{error:'Your email changed. Please sign in again.'})
  }else{
   if(email.length>254||!/^\S+@\S+\.\S+$/.test(email))return reply(origin,400,{error:'Enter a valid email address.'})
   const password=String(payload.password||'')
   if(password.length<1||password.length>128)return reply(origin,400,{error:'Enter your password.'})
   if(payload.intent==='register'&&(password.length<10||!['tutor','student'].includes(payload.role)||!String(payload.name||'').trim()))return reply(origin,400,{error:'Enter your name, account type and a password of at least 10 characters.'})
  }
  // The ticket authenticates resend/verify. Public starts are limited by email and network.
  const ip=(req.headers.get('x-forwarded-for')||req.headers.get('x-real-ip')||'unknown').split(',').pop()!.trim()
  const budget=await operation('reserve',{email_hash:await hash('email:'+email),ip_hash:await hash('ip:'+ip)})
  if(!budget.ok)return reply(origin,429,{error:budget.error})
  if(!account){
   const found=await operation('lookup',{email})
   if(found.user_id){
    account=await recipient(found.user_id)
    const passwordClient=createClient(url,publicKey,{auth:{persistSession:false,autoRefreshToken:false}})
    if(!await checkInitialPassword(passwordClient.auth,email,String(payload.password)))return reply(origin,400,{error:'The email or password is incorrect. Please check your details.'})
   }
   else if(payload.intent==='register'){
    stage='create-account'
    const created=await admin.auth.admin.createUser({email,password:String(payload.password),email_confirm:false,user_metadata:{name:String(payload.name).trim().slice(0,80),role:payload.role}})
    if(created.error||!created.data.user)throw new Error('Account creation unavailable')
    account=created.data.user
   }else return reply(origin,400,{error:'Please create an account or check your email and password.'})
  }
  if(payload.action==='start'){
   const bytes=crypto.getRandomValues(new Uint8Array(32));ticket=Array.from(bytes,v=>v.toString(16).padStart(2,'0')).join('');ticketHash=await hash('ticket:'+ticket)
  }
  const code=randomCode()
  stage='prepare-code'
  const issue=await operation('prepare',{ticket_hash:ticketHash,user_id:account.id,email_hash:await hash('email:'+email),code_hash:await hash('code:'+ticket+':'+code)})
  const host=Deno.env.get('SMTP_HOST'),user=Deno.env.get('SMTP_USER'),raw=Deno.env.get('SMTP_PASSWORD'),from=Deno.env.get('SMTP_FROM'),port=Number(Deno.env.get('SMTP_PORT')||465)
  const pass=host==='smtp.gmail.com'?raw?.replace(/\s/g,''):raw
  if(!host||!user||!pass||!from||port!==465)throw new Error('Email sender unavailable')
  transport=nodemailer.createTransport({host,port,secure:true,auth:{user,pass},tls:{minVersion:'TLSv1.2',rejectUnauthorized:true},connectionTimeout:10000,greetingTimeout:10000,socketTimeout:15000,pool:false})
  stage='send-email'
  const sent=await transport.sendMail({from,to:account.email,subject:'Tutormela verification code',text:`Your Tutormela verification code is ${code}.\n\nEnter it in the Tutormela sign-in window. It expires in 5 minutes. Do not share this code.\n\nIf you did not request this email, you can ignore it.`,html:`<div style="font-family:Arial,sans-serif;color:#263c38;padding:24px;max-width:480px"><h2 style="font-size:20px">Tutormela</h2><p>Your verification code</p><p style="font-size:32px;letter-spacing:8px">${code}</p><p>Enter it in the Tutormela sign-in window within 5 minutes. Do not share this code.</p><p>If you did not request this email, you can ignore it.</p></div>`})
  if(sent.rejected?.length||!sent.accepted?.length)throw Object.assign(new Error('Recipient not accepted'),{code:'ERECIPIENT'})
  stage='mark-delivered';const delivered=await operation('delivered',{ticket_hash:ticketHash});if(!delivered.ok)throw new Error('Verification expired')
  return reply(origin,200,{sent:true,ticket,resendAfter:60,expiresAt:issue.expiresAt})
 }catch(error){
  console.error('First-use verification failed',{stage,category:String((error as {code?:string})?.code||'UNAVAILABLE').replace(/[^A-Z0-9_]/gi,'').slice(0,24)})
  const setup=(error as {code?:string})?.code==='ESETUP'
  return reply(origin,setup?503:502,{error:setup?'Email verification setup is pending. Please try again later.':'We could not send or verify your code. Please try again.',...(ticket?{ticket}:{})})
 }finally{transport?.close()}
})
