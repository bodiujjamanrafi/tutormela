import {spawnSync} from 'node:child_process'
import {chmodSync,existsSync,readdirSync,writeFileSync,unlinkSync} from 'node:fs'
import {join} from 'node:path'
import {homedir} from 'node:os'
import {privateEnvironment,smtpConfiguration,projectRoot,projectRef} from './lib/smtp-config.js'
function cliPath(){if(process.env.SUPABASE_CLI)return process.env.SUPABASE_CLI;const cache=join(homedir(),'.npm/_npx');if(existsSync(cache))for(const entry of readdirSync(cache)){const candidate=join(cache,entry,'node_modules',`@supabase/cli-${process.platform}-${process.arch}`,'bin/supabase');if(existsSync(candidate))return candidate}return 'supabase'}
const cli=cliPath(),file=join(projectRoot,'supabase/.env.smtp-upload.local')
try{
 const env=privateEnvironment(),config=smtpConfiguration(env)
 if(env.SUPABASE_ACCESS_TOKEN){
  const endpoint=`https://api.supabase.com/v1/projects/${projectRef}/secrets`
  const headers={Authorization:`Bearer ${env.SUPABASE_ACCESS_TOKEN.trim()}`,'Content-Type':'application/json'}
  const listed=await fetch(endpoint,{headers})
  if(!listed.ok)throw new Error(`Supabase cannot read project secret names (HTTP ${listed.status}). Check that your token includes the Tutormela project and secrets-read permission.`)
  const current=await listed.json();if(!Array.isArray(current))throw new Error('Unexpected Supabase response. No secret values were logged.')
  const names=new Set(current.map(item=>item.name))
  const values={SMTP_HOST:config.host,SMTP_PORT:String(config.port),SMTP_USER:config.user,SMTP_PASSWORD:config.pass,SMTP_FROM:config.from}
  if(!names.has('OTP_HMAC_SECRET')){if((env.OTP_HMAC_SECRET||'').length<32)throw new Error('Add a private OTP_HMAC_SECRET of at least 32 characters.');values.OTP_HMAC_SECRET=env.OTP_HMAC_SECRET}
  if(!names.has('APP_ORIGINS'))values.APP_ORIGINS=env.APP_ORIGINS||'http://127.0.0.1:5173,http://localhost:5173'
  const saved=await fetch(endpoint,{method:'POST',headers,body:JSON.stringify(Object.entries(values).map(([name,value])=>({name,value})))})
  if(!saved.ok){if(saved.status===403)throw new Error('Supabase token is missing edge_functions_secrets_write for the Tutormela project. Update the token permission and run this command again.');throw new Error(`Supabase could not save SMTP secrets (HTTP ${saved.status}). No secret values were logged.`)}
  const confirmed=await fetch(endpoint,{headers});if(!confirmed.ok)throw new Error('Secrets saved, but verification of secret names failed.');const checkedNames=new Set((await confirmed.json()).map(item=>item.name));if(!['SMTP_HOST','SMTP_PORT','SMTP_USER','SMTP_PASSWORD','SMTP_FROM','OTP_HMAC_SECRET'].every(name=>checkedNames.has(name)))throw new Error('SMTP secret-name verification failed.')
  console.log('Verified: Gmail SMTP credentials are stored as Supabase server-only secrets. Existing OTP signing secrets and origins were preserved.')
  process.exit(0)
 }
 const childEnv={...process.env,...(env.SUPABASE_ACCESS_TOKEN?{SUPABASE_ACCESS_TOKEN:env.SUPABASE_ACCESS_TOKEN}:{})}
 const result=spawnSync(cli,['secrets','list','--project-ref',projectRef,'--output','json'],{cwd:projectRoot,env:childEnv,encoding:'utf8',stdio:['ignore','pipe','pipe']})
 if(result.status!==0)throw new Error('Supabase login is required. Run npx supabase@2.109.1 login, then npm run smtp:configure. Secret values were not printed.')
 let secrets;try{secrets=JSON.parse(result.stdout)}catch{throw new Error('Could not read Supabase secret names. No configuration was changed.')}
 if(!Array.isArray(secrets))throw new Error('Unexpected Supabase secret list. No configuration was changed.')
 const existing=new Set(secrets.map(s=>s.name))
 const values={SMTP_HOST:config.host,SMTP_PORT:String(config.port),SMTP_USER:config.user,SMTP_PASSWORD:config.pass,SMTP_FROM:config.from}
 if(!existing.has('OTP_HMAC_SECRET')){if((env.OTP_HMAC_SECRET||'').length<32)throw new Error('A server-only OTP_HMAC_SECRET of at least 32 characters is required.');values.OTP_HMAC_SECRET=env.OTP_HMAC_SECRET}
 if(!existing.has('APP_ORIGINS'))values.APP_ORIGINS=env.APP_ORIGINS||'http://127.0.0.1:5173,http://localhost:5173'
 // The private file is ignored by Git, readable only by its owner, and always removed.
 writeFileSync(file,Object.entries(values).map(([k,v])=>`${k}=${JSON.stringify(v)}`).join('\n')+'\n',{mode:0o600});chmodSync(file,0o600)
 const saved=spawnSync(cli,['secrets','set','--project-ref',projectRef,'--env-file',file],{cwd:projectRoot,env:childEnv,encoding:'utf8',stdio:['ignore','pipe','pipe']})
 if(saved.status!==0){let detail=saved.stderr+' '+saved.stdout;for(const value of [...Object.values(env),config.pass])if(value&&value.length>7)detail=detail.replaceAll(value,'[redacted]');detail=detail.replace(/sbp_[A-Za-z0-9]+/g,'[redacted]').replace(/sb_secret_[A-Za-z0-9_-]+/g,'[redacted]');throw new Error('Supabase SMTP setup failed: '+detail.slice(0,1200))}
 console.log('SMTP credentials were saved as Supabase server-only secrets. Existing signing secrets and origins were preserved.')
}catch(error){console.error(error.message);process.exitCode=1}finally{if(existsSync(file))unlinkSync(file)}
