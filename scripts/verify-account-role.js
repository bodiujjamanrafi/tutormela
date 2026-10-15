import assert from 'node:assert/strict'
import {resolveAccountRole} from '../src/lib/account-role.js'
const student={id:'own',role:'student',onboarding_complete:true}
let changes=0
const tutor=await resolveAccountRole({account:student,requestedRole:'tutor',chooseRole:async role=>{assert.equal(role,'tutor');changes++},reload:async()=>({...student,role:'tutor'})})
assert.equal(tutor.role,'tutor');assert.equal(changes,1)
for(const role of ['tutor','admin'])assert.equal((await resolveAccountRole({account:{...student,role},requestedRole:'student',chooseRole:()=>assert.fail('Must not downgrade roles')})).role,role)
assert.equal((await resolveAccountRole({account:student,requestedRole:'student',chooseRole:()=>assert.fail('Student account must stay student')})).role,'student')
await assert.rejects(()=>resolveAccountRole({account:student,requestedRole:'tutor',chooseRole:async()=>{},reload:async()=>student}),/could not be activated/)
await assert.rejects(()=>resolveAccountRole({account:student,requestedRole:'tutor',chooseRole:async()=>{},reload:async()=>({...student,id:'someone-else',role:'tutor'})}),/could not be activated/)
await assert.rejects(()=>resolveAccountRole({account:student,requestedRole:'tutor',chooseRole:async()=>{throw new Error('Permission denied')},reload:()=>assert.fail('Never pretend role changed')}),/Permission denied/)
console.log('Account role checks passed: persisted tutor activation, owner identity matching, preserved tutor/admin roles, and failure rejection.')
