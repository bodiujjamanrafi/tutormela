import nodemailer from 'nodemailer'
import {smtpConfiguration,transportOptions,safeSmtpError} from './lib/smtp-config.js'
let transport
try{
 const config=smtpConfiguration();transport=nodemailer.createTransport(transportOptions(config))
 await transport.verify();console.log('Gmail SMTP authentication and TLS verification succeeded.')
 if(process.argv.includes('--send-test')){
  const result=await transport.sendMail({from:config.from,to:config.user,subject:'Tutormela email delivery test',text:'Tutormela successfully connected to your Gmail SMTP sender.\n\nThis is a delivery test, not a sign-in code. Sign in to Tutormela with your real account to request a verification code.\n\nNo app password or secret is included in this email.',html:'<div style="font-family:Arial,sans-serif;max-width:480px;margin:auto;padding:24px;color:#263c38"><h2>Tutormela</h2><p>Your Gmail SMTP sender is connected.</p><p>This is a delivery test, not a sign-in code. Sign in to Tutormela with your real account to request a verification code.</p><p>No app password or secret is included in this email.</p></div>'})
  if(result.rejected?.length||!result.accepted?.length)throw Object.assign(new Error('Message rejected'),{code:'MESSAGE_REJECTED'})
  console.log('Gmail accepted the test email for delivery to the configured sender inbox. Inbox arrival must be confirmed by the recipient.')
 }
}catch(error){console.error(safeSmtpError(error));process.exitCode=1}finally{transport?.close()}
