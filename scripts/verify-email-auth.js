import assert from 'node:assert/strict'
import {passwordSignIn,isRealEmailAuth} from '../src/lib/email-auth.js'
function scenario(error=null,enabled=true,sent={sent:true}){
 const calls=[];return {calls,helpers:{auth:{signInWithPassword:async args=>{calls.push({type:'password',email:args.email});return {error}}},codeEnabled:async()=>enabled,sendCode:async()=>{calls.push({type:'send'});if(sent instanceof Error)throw sent;return sent},confirmEmail:async args=>{calls.push({type:'confirm',email:args.email});return {verificationRequired:true,signupTicket:'test-ticket',email:args.email}},currentUser:async()=>{calls.push({type:'profile'});return {id:'verified-user'}}}}
}
const credentials={email:' student@example.test ',password:'test-only'}
const pending=scenario({code:'email_not_confirmed',message:'Email not confirmed'})
assert.deepEqual(await passwordSignIn(pending.helpers,credentials),{verificationRequired:true,signupTicket:'test-ticket',email:'student@example.test'})
assert.equal(pending.calls.some(c=>c.type==='send'),false)
assert.equal(pending.calls.some(c=>c.type==='profile'),false)
assert.deepEqual(pending.calls.map(c=>c.type),['password','confirm'])
const login=scenario();assert.deepEqual(await passwordSignIn(login.helpers,credentials),{verificationRequired:true,email:'student@example.test'});assert.deepEqual(login.calls.map(c=>c.type),['password','send'])
const invalid=scenario({code:'invalid_credentials',message:'Invalid login credentials'});await assert.rejects(passwordSignIn(invalid.helpers,credentials),/Invalid login/);assert.equal(invalid.calls.length,1)
const failure=scenario(null,true,new Error('Email temporarily unavailable'));const failed=await passwordSignIn(failure.helpers,credentials);assert.equal(failed.verificationRequired,true);assert.equal(failed.deliveryError,'Email temporarily unavailable');assert.equal(failure.calls.some(c=>c.type==='profile'),false)
const unsent=scenario(null,true,{sent:false});assert.ok((await passwordSignIn(unsent.helpers,credentials)).deliveryError)
assert.equal(isRealEmailAuth('/auth/login'),true);assert.equal(isRealEmailAuth('/auth/register'),true);assert.equal(isRealEmailAuth('/auth/demo'),false)
console.log('Email flow checks passed: unconfirmed signup, password failures, successful OTP requests, delivery failures, and separation from demo sign-in.')
