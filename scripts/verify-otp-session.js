import assert from 'node:assert/strict'
import {createVerifiedEmailSession,checkInitialPassword} from '../supabase/functions/email-signup-code/verified-session.js'
const account={id:'verified-account',email:'verified@example.test'},session={access_token:'test-user-token',refresh_token:'test-refresh-token'}
let calls=[]
const admin={generateLink:async args=>{calls.push(['generate',args]);return {data:{user:account,properties:{hashed_token:'server-only-test-hash'}}}}}
const auth={verifyOtp:async args=>{calls.push(['exchange',args]);return {data:{user:account,session}}},signInWithPassword:async()=>{throw new Error('Password must not be requested after OTP')}}
assert.deepEqual(await createVerifiedEmailSession(admin,auth,account),session)
assert.deepEqual(calls,[['generate',{type:'magiclink',email:account.email}],['exchange',{token_hash:'server-only-test-hash',type:'email'}]])
await assert.rejects(createVerifiedEmailSession({generateLink:async()=>({error:{message:'Unavailable'}})},auth,account),/Session generation/)
await assert.rejects(createVerifiedEmailSession({generateLink:async()=>({data:{user:{id:'different-user'},properties:{hashed_token:'hash'}}})},auth,account),/Session generation/)
await assert.rejects(createVerifiedEmailSession(admin,{verifyOtp:async()=>({data:{user:{id:'different-user'},session}})},account),/Verified sign-in/)
await assert.rejects(createVerifiedEmailSession(admin,{verifyOtp:async()=>({error:{message:'Expired'}})},account),/Verified sign-in/)
calls=[]
assert.equal(await checkInitialPassword({signInWithPassword:async()=>({error:{code:'invalid_credentials'}})},account.email,'wrong'),false)
assert.equal(await checkInitialPassword({signInWithPassword:async()=>({error:{code:'email_not_confirmed'}})},account.email,'test'),true)
assert.equal(await checkInitialPassword({signInWithPassword:async args=>{calls.push(args);return {data:{session}}},signOut:async args=>{calls.push(args);return {error:null}}},account.email,'test'),true)
assert.deepEqual(calls,[{email:account.email,password:'test'},{scope:'local'}])
console.log('OTP session checks passed: direct session without a second password, user binding, provider failures, initial password validation and temporary-session cleanup.')
