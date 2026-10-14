import {spawn} from 'node:child_process';
import assert from 'node:assert/strict';
import {rmSync} from 'node:fs';
const dbName='verification.sqlite';
const server=spawn(process.execPath,['server/index.js'],{env:{...process.env,PORT:'3101',TUTORMELA_DEMO:'1',TUTORMELA_DB:dbName},stdio:['ignore','pipe','inherit']});
let checks=0;
const check=(v,message)=>{assert.ok(v,message);checks++;console.log('✓ '+message)};
async function call(path,{method='GET',body,cookie='',origin}={}){const r=await fetch('http://127.0.0.1:3101/api'+path,{method,headers:{...(body?{'Content-Type':'application/json'}:{}),...(cookie?{cookie}:{}),...(origin?{origin}: {})},...(body?{body:JSON.stringify(body)}:{})});return {status:r.status,body:await r.json(),cookie:r.headers.get('set-cookie')?.split(';')[0]}}
async function login(role){return (await call('/auth/login',{method:'POST',body:{email:`${role}@tutormela.local`,password:'Tutormela2026!'}})).cookie}
try{
 await new Promise((r,j)=>{server.stdout.once('data',r);server.once('error',j);server.once('exit',()=>j(new Error('Server failed to start')))});
 const catalog=await call('/catalog');check(catalog.body.districts.length===64,'All 64 districts available');
 const list=await call('/profiles');check(list.body.length===8,'Approved example profiles visible');check(list.body.every(p=>!('email' in p)&&!('user_id' in p)&&!('contact' in p)),'Public profiles expose no account or contact data');
 check((await call('/saved')).status===401,'Anonymous private access denied');
 const student=await login('student'),tutor=await login('tutor'),admin=await login('admin');check(student&&tutor&&admin,'Student, tutor, and admin sign-in works');
 check((await call('/admin/profiles',{cookie:student})).status===403,'Students cannot access admin queue');check((await call('/profile',{cookie:student,method:'PUT',body:{}})).status===403,'Students cannot change tutor profiles');check((await call('/saved',{cookie:tutor})).status===403,'Tutor cannot read student shortlists');
 check((await call('/auth/register',{method:'POST',body:{name:'Forbidden',email:'forbidden@example.test',password:'StrongPassword1!',role:'admin'}})).status===400,'Public registration cannot create administrators');
 check((await call('/saved',{cookie:student,method:'POST',body:{profileId:1},origin:'https://untrusted.example'})).status===403,'Cross-origin writes rejected');
 await call('/saved',{cookie:student,method:'POST',body:{profileId:1}});check((await call('/saved',{cookie:student})).body[0].id===1,'Saved tutors persist on the server');
 const request={profileId:1,studentName:'Test learner',className:'Class 9–10 / SSC',subject:'Mathematics',mode:'Online',message:'Test request for evening tuition',contact:'test@example.test'};
 check((await call('/requests',{cookie:student,method:'POST',body:request})).status===201,'Student can submit a private request');check((await call('/requests',{cookie:student,method:'POST',body:request})).status===409,'Duplicate pending requests prevented');
 const inbox=(await call('/requests',{cookie:tutor})).body;check(inbox.length===1&&inbox[0].contact===request.contact,'Only recipient tutor sees request and shared contact');check((await call('/requests',{cookie:admin})).status===403,'Admin cannot browse private student requests');
 const stranger=await call('/auth/register',{method:'POST',body:{name:'Other tutor',email:'other@example.test',password:'StrongPassword1!',role:'tutor'}});check((await call(`/requests/${inbox[0].id}`,{cookie:stranger.cookie,method:'PATCH',body:{status:'accepted'}})).status===403,'Another tutor cannot accept the request');
 check((await call(`/requests/${inbox[0].id}`,{cookie:tutor,method:'PATCH',body:{status:'accepted'}})).status===200,'Recipient tutor can accept request');check((await call('/requests',{cookie:student})).body[0].status==='accepted','Student dashboard reflects tutor response');
 const own=(await call('/profile',{cookie:tutor})).body;check((await call('/profile',{cookie:tutor,method:'PUT',body:{...own,photo:'data:image/png;base64,YWJj'}})).status===400,'Invalid uploaded images rejected');
 check((await call('/profile',{cookie:tutor,method:'PUT',body:{...own,aboutEn:'Updated teaching introduction.'}})).body.status==='pending','Profile edits require approval');check(!(await call('/profiles')).body.some(p=>p.id===1),'Pending profile hidden from public search');
 check((await call('/admin/profiles/1',{cookie:admin,method:'PATCH',body:{status:'rejected'}})).status===400,'Rejection requires helpful feedback');
 await call('/admin/profiles/1',{cookie:admin,method:'PATCH',body:{status:'approved'}});check((await call('/profiles')).body.some(p=>p.id===1),'Admin approval publishes profile');
 await call('/auth/logout',{cookie:student,method:'POST',body:{}});check((await call('/saved',{cookie:student})).status===401,'Signing out invalidates the session');
 console.log(`\n${checks} workflow and permission checks passed.`);
}finally{server.kill();await new Promise(r=>server.once('exit',r));for(const suffix of ['','-wal','-shm'])rmSync(`data/${dbName}${suffix}`,{force:true})}
