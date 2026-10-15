import assert from 'node:assert/strict'
import {handoffSignIn} from '../src/lib/sign-in-handoff.js'
for(const [role,route] of [['tutor','dashboard'],['student','browse'],['admin','dashboard']]){
 let release;const events=[]
 const hydration=new Promise(resolve=>{release=resolve})
 const done=handoffSignIn({user:{id:'verified-user',role},onAuthenticated:()=>events.push('close login'),navigate:r=>events.push(r),hydrate:()=>hydration,onError:()=>events.push('error')})
 assert.deepEqual(events,['close login',route],'Login must close and navigate before private data finishes loading')
 release();await done
}
const events=[]
await handoffSignIn({user:{id:'verified-user',role:'tutor'},onAuthenticated:()=>events.push('authenticated'),navigate:route=>events.push(route),hydrate:async()=>{throw new Error('Requests unavailable')},afterSignIn:async()=>events.push('saved action'),onError:e=>events.push(e.message)})
assert.deepEqual(events,['authenticated','dashboard','Requests unavailable','saved action'])
await assert.rejects(()=>handoffSignIn({user:null,onAuthenticated:()=>{throw new Error('Must never fabricate a signed-in user')}}),/verified/)
console.log('Sign-in handoff checks passed: immediate role-based navigation, non-blocking private data and no redirect without a verified account.')
