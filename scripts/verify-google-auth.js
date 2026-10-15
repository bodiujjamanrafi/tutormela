import assert from 'node:assert/strict'
import {createHash} from 'node:crypto'
import {firebaseGoogleSession,googleError} from '../src/lib/google-auth-flow.js'
const verifiedGoogleUser={id:'mock-user',email:'user@example.test',email_confirmed_at:'2026-10-15T00:00:00Z',identities:[{provider:'google'}]}
let cleared=0,seenHash,exchangeCall
const result=await firebaseGoogleSession({getCredential:async hash=>{seenHash=hash;return {idToken:'mock-google-id-token',accessToken:'mock-google-access-token'}},exchange:async credentials=>{exchangeCall=credentials;return {data:{session:{access_token:'mock-supabase-token'},user:{id:'mock-user'}}}},verifyUser:async token=>{assert.equal(token,'mock-supabase-token');return {data:{user:verifiedGoogleUser}}},clear:async()=>{cleared++}})
assert.equal(result.user.id,'mock-user')
assert.equal(exchangeCall.provider,'google')
assert.equal(createHash('sha256').update(exchangeCall.nonce).digest('hex'),seenHash)
assert.equal(exchangeCall.token,'mock-google-id-token')
assert.equal(exchangeCall.access_token,'mock-google-access-token')
assert.equal(cleared,1)
await assert.rejects(()=>firebaseGoogleSession({getCredential:async()=>{throw {code:'auth/popup-closed-by-user'}},exchange:async()=>{throw new Error('Must not exchange a cancelled login')},clear:async()=>{cleared++}}),/cancelled/)
await assert.rejects(()=>firebaseGoogleSession({getCredential:async()=>({idToken:'mock-google-id-token'}),exchange:async()=>({error:{code:'provider_disabled'}}),clear:async()=>{cleared++}}),/activation/)
await assert.rejects(()=>firebaseGoogleSession({getCredential:async()=>({}),exchange:async()=>{throw new Error('Must not exchange a missing token')},clear:async()=>{cleared++}}),/sign-in token/)
await assert.rejects(()=>firebaseGoogleSession({getCredential:async()=>({idToken:'mock-google-id-token'}),exchange:async()=>({data:{user:{id:'mock-user'}}}),clear:async()=>{cleared++}}),/website session/)
assert.equal(cleared,5)
assert.match(googleError({code:'auth/unauthorized-domain'}),/localhost/)
assert.match(googleError({code:'auth/popup-blocked'}),/pop-ups/)
console.log('Google auth checks passed: nonce binding, correct token exchange, missing-token/session rejection, cancellation, setup errors and temporary Firebase session cleanup.')

let credentialCalls=0,providerCleanup=0
await assert.rejects(()=>firebaseGoogleSession({checkProvider:async()=>{throw new Error('Google is not active')},getCredential:async()=>{credentialCalls++;return {idToken:'must-not-be-used'}},exchange:async()=>{throw new Error('Must not exchange while provider is disabled')},clear:async()=>{providerCleanup++}}),/not active/)
assert.equal(credentialCalls,0)
assert.equal(providerCleanup,1)
console.log('Disabled provider is detected before opening the Google authorization popup.')

for(const user of [{...verifiedGoogleUser,id:'another-user'},{...verifiedGoogleUser,email_confirmed_at:null},{...verifiedGoogleUser,identities:[{provider:'email'}]}]){
 await assert.rejects(()=>firebaseGoogleSession({getCredential:async()=>({idToken:'mock-google-id-token'}),exchange:async()=>({data:{session:{access_token:'mock-supabase-token'},user:{id:'mock-user'}}}),verifyUser:async()=>({data:{user}}),clear:async()=>{}}),/could not be verified/)
}
await assert.rejects(()=>firebaseGoogleSession({getCredential:async()=>({idToken:'mock-google-id-token'}),exchange:async()=>({data:{session:{access_token:'mock-supabase-token'},user:{id:'mock-user'}}}),verifyUser:async()=>({error:{message:'Session expired'}}),clear:async()=>{}}),/could not be verified/)
console.log('Server verification checks passed: confirmed email, linked Google identity, exact account match and rejection of invalid sessions.')
