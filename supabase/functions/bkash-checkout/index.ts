import {createClient} from 'npm:@supabase/supabase-js@2.117.3'
import {gateway,checkoutUrl,matchesPayment,type Payment} from './gateway.ts'
const project=Deno.env.get('SUPABASE_URL')!
const service=createClient(project,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}})
const allowed=(Deno.env.get('APP_ORIGINS')||'http://127.0.0.1:5173,http://localhost:5173').split(',').map(s=>s.trim())
const cors=(origin:string)=>({'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS','Cache-Control':'no-store','Vary':'Origin'})
const reply=(origin:string,status:number,body:unknown)=>Response.json(body,{status,headers:cors(origin)})
async function order(action:string,data:Record<string,unknown>){const r=await service.rpc('tm_bkash_order',{p_action:action,p_data:data});if(r.error)throw new Error('Order operation failed');return r.data}
async function signature(id:string,secret:string){const enc=new TextEncoder(),key=await crypto.subtle.importKey('raw',enc.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);return Array.from(new Uint8Array(await crypto.subtle.sign('HMAC',key,enc.encode('bkash-order:'+id))),v=>v.toString(16).padStart(2,'0')).join('')}
async function validSignature(id:string,value:string,secret:string){if(!/^[a-f0-9]{64}$/.test(value))return false;const enc=new TextEncoder(),key=await crypto.subtle.importKey('raw',enc.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['verify']);const bytes=Uint8Array.from(value.match(/../g)!,v=>parseInt(v,16));return crypto.subtle.verify('HMAC',key,bytes,enc.encode('bkash-order:'+id))}
Deno.serve(async req=>{
 const origin=req.headers.get('origin')||'',url=new URL(req.url),callback=req.method==='GET'&&url.searchParams.has('order')
 if(!callback&&!allowed.includes(origin))return reply('',403,{error:'Website origin not allowed.'})
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers:cors(origin)})
 const environment=Deno.env.get('BKASH_ENVIRONMENT')||'sandbox',appKey=Deno.env.get('BKASH_APP_KEY')||'',appSecret=Deno.env.get('BKASH_APP_SECRET')||'',username=Deno.env.get('BKASH_USERNAME')||'',password=Deno.env.get('BKASH_PASSWORD')||'',secret=Deno.env.get('BKASH_CALLBACK_SECRET')||''
 const configured=Deno.env.get('BKASH_ENABLED')==='true'&&Deno.env.get('BKASH_API_VERSION')==='v1.2.0-beta'&&['sandbox','live'].includes(environment)&&appKey&&appSecret&&username&&password&&secret.length>=32
 if(!configured)return reply(origin,503,{error:'bKash payments are not connected yet. No payment has been taken.'})
 const api=gateway({environment,appKey,appSecret,username,password})
 async function reconcile(o:Awaited<ReturnType<typeof order>>,execute=false){
  if(o.status==='paid'||!o.payment_id)return o
  // A durable claim permits one execute call only; ambiguous failures are recovered through query.
  let payment:Payment|undefined
  if(execute&&(await order('claim',{order:o.id})).claimed){try{payment=await api.execute(o.payment_id)}catch{/* Query the gateway after ambiguous execution; never execute a second time. */}}
  if(!payment||payment.transactionStatus!=='Completed'){try{payment=await api.query(o.payment_id)}catch{return o}}
  if(payment.transactionStatus==='Completed'){
   if(!matchesPayment(payment,o))throw new Error('Gateway payment mismatch')
   return order('settle',{order:o.id,paymentID:payment.paymentID,invoice:payment.merchantInvoiceNumber,amount:payment.amount,currency:payment.currency,transactionStatus:payment.transactionStatus,trxID:payment.trxID})
  }
  return o
 }
 try{
  if(callback){
   const id=url.searchParams.get('order')||''
   if(!/^[0-9a-f-]{36}$/i.test(id)||!await validSignature(id,url.searchParams.get('state')||'',secret))return reply('',400,{error:'Invalid payment callback.'})
   let o=await order('read',{order:id})
   if(!allowed.includes(o.return_origin)||o.environment!==environment||o.payment_id!==url.searchParams.get('paymentID'))return reply('',400,{error:'Invalid payment reference.'})
   await api.authorize()
   // Browser status is only a trigger to query/execute; it never proves a successful charge.
   o=await reconcile(o,url.searchParams.get('status')==='success')
   if(o.status!=='paid'&&url.searchParams.get('status')==='cancel')o=await order('cancel',{order:id})
   return new Response(null,{status:303,headers:{Location:o.return_origin+'/?payment_order='+encodeURIComponent(id)+'#/subscriptions','Cache-Control':'no-store','Referrer-Policy':'no-referrer'}})
  }
  if(req.method!=='POST')return reply(origin,405,{error:'Method not allowed.'})
  const token=(req.headers.get('authorization')||'').replace(/^Bearer /,'')
  const client=createClient(project,Deno.env.get('SUPABASE_ANON_KEY')!,{global:{headers:{Authorization:'Bearer '+token}},auth:{persistSession:false,autoRefreshToken:false}})
  const auth=await client.auth.getUser(token)
  if(auth.error||!auth.data.user)return reply(origin,401,{error:'Sign in before starting a payment.'})
  const verified=await client.rpc('tm_auth_session_ready')
  if(verified.error||verified.data!==true)return reply(origin,403,{error:'Verify your sign-in before paying.'})
  const body=await req.json()
  if(body.action==='status'){
   let o=await order('read',{order:body.order})
   if(o.user_id!==auth.data.user.id)return reply(origin,404,{error:'Payment not found.'})
   if(o.environment!==environment)return reply(origin,409,{error:'Payment environment has changed. Contact support.'})
   if(o.status==='pending'){await api.authorize();o=await reconcile(o)}
   return reply(origin,200,{status:o.status==='creating'?'pending':o.status,environment:o.environment})
  }
  if(body.action!=='start'||!['starter','growth','professional'].includes(body.plan)||body.returnOrigin!==origin)return reply(origin,400,{error:'Invalid checkout request.'})
  let o=await order('reserve',{user:auth.data.user.id,plan:body.plan,environment,origin})
  if(o.checkout_url)return reply(origin,200,{checkoutUrl:checkoutUrl(o.checkout_url)})
  try{
   await api.authorize()
   const callbackURL=project+'/functions/v1/bkash-checkout?order='+o.id+'&state='+await signature(o.id,secret)
   const created=await api.create({mode:'0011',payerReference:o.id,callbackURL,amount:o.amount.toFixed(2),currency:'BDT',intent:'sale',merchantInvoiceNumber:o.invoice})
   if(!created.paymentID||!created.bkashURL)throw new Error('Invalid checkout response')
   const redirect=checkoutUrl(created.bkashURL)
   o=await order('bind',{order:o.id,paymentID:created.paymentID,checkoutUrl:redirect})
   return reply(origin,200,{checkoutUrl:o.checkout_url})
  }catch{await order('fail',{order:o.id});throw new Error('Checkout could not be opened')}
 }catch{
  // Never return gateway bodies, credentials, customer phone numbers or tokens.
  return reply(origin,502,{error:callback?'Payment confirmation is pending. Return to Posting plans and check your payment.':'Payment could not be completed. If a checkout is already open, finish it before starting another.'})
 }
})
