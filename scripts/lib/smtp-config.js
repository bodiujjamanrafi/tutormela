import {readFileSync} from 'node:fs'
import {parseEnv} from 'node:util'
import {fileURLToPath} from 'node:url'
export const projectRoot=fileURLToPath(new URL('../../',import.meta.url))
export const projectRef='zpjdlkrtscxyucqudbpd'
export function privateEnvironment(){return {...parseEnv(readFileSync(new URL('../../.env.local',import.meta.url),'utf8')),...process.env}}
export function smtpConfiguration(env=privateEnvironment()){
 const host=env.SMTP_HOST||'smtp.gmail.com',port=Number(env.SMTP_PORT||465),user=env.SMTP_USER
 let pass=env.SMTP_PASSWORD||env.App_password||''
 if(host==='smtp.gmail.com')pass=pass.replace(/\s/g,'')
 if(!user||!/^\S+@\S+\.\S+$/.test(user))throw new Error('SMTP_USER must contain the sender email address.')
 if(!pass)throw new Error('Add your SMTP app password to .env.local.')
 if(port!==465)throw new Error('The deployed email service requires encrypted SMTP on port 465.')
 if(host==='smtp.gmail.com'&&!/^[A-Za-z]{16}$/.test(pass))throw new Error('The Gmail app password must contain 16 letters, with optional spaces.')
 return {host,port,user,pass,from:env.SMTP_FROM||`Tutormela <${user}>`}
}
export function transportOptions(config){return {host:config.host,port:config.port,secure:true,auth:{user:config.user,pass:config.pass},tls:{minVersion:'TLSv1.2',rejectUnauthorized:true},connectionTimeout:10000,greetingTimeout:10000,socketTimeout:15000,pool:false}}
export function safeSmtpError(error){
 const code=String(error?.code||'UNKNOWN').replace(/[^A-Z0-9_]/gi,'').slice(0,30)
 const status=Number(error?.responseCode)||''
 if(code==='EAUTH')return `Gmail rejected SMTP authentication (${status||code}). Check that the app password belongs to SMTP_USER.`
 if(['ETIMEDOUT','ESOCKET','ECONNECTION','ENOTFOUND','ECONNREFUSED'].includes(code))return `SMTP connection failed (${code}). Check network access to the encrypted SMTP server.`
 return `SMTP verification failed (${code}${status?`, ${status}`:''}). No credential values were logged.`
}
