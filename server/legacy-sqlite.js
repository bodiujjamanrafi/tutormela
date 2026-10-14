import http from 'node:http';
import { DatabaseSync } from 'node:sqlite';
import { randomBytes, scryptSync, timingSafeEqual, createHash } from 'node:crypto';
import { mkdirSync, readFileSync, existsSync } from 'node:fs';
import { resolve, extname, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { districts, subjects, classes, modes, days, seeds } from './catalog.js';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
mkdirSync(resolve(root,'data'),{recursive:true});
const db=new DatabaseSync(resolve(root,'data',process.env.TUTORMELA_DB || (process.env.TUTORMELA_DEMO==='1'?'demo.sqlite':'tutormela.sqlite')));
db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, name TEXT NOT NULL,email TEXT UNIQUE NOT NULL,password TEXT NOT NULL,role TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sessions(token TEXT PRIMARY KEY,user_id INTEGER REFERENCES users(id),expires INTEGER);
CREATE TABLE IF NOT EXISTS profiles(id INTEGER PRIMARY KEY,user_id INTEGER UNIQUE REFERENCES users(id),body TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'pending',reason TEXT DEFAULT '',sample INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS saved(user_id INTEGER REFERENCES users(id),profile_id INTEGER REFERENCES profiles(id),PRIMARY KEY(user_id,profile_id));
CREATE TABLE IF NOT EXISTS requests(id INTEGER PRIMARY KEY,user_id INTEGER REFERENCES users(id),profile_id INTEGER REFERENCES profiles(id),body TEXT NOT NULL,status TEXT DEFAULT 'pending',created TEXT DEFAULT CURRENT_TIMESTAMP);`);
const hash=p=>{const salt=randomBytes(16).toString('hex');return salt+':'+scryptSync(p,salt,64).toString('hex')};
const verify=(p,h)=>{const [salt,key]=h.split(':'); return timingSafeEqual(scryptSync(p,salt,64),Buffer.from(key,'hex'))};
const safeUser=u=>u&&({id:u.id,name:u.name,email:u.email,role:u.role});
const demo=process.env.TUTORMELA_DEMO==='1';
if(demo&&!db.prepare('SELECT id FROM users LIMIT 1').get()){
 for(const [name,email,role] of [['Ayesha Rahman','student@tutormela.local','student'],['Nafisa Rahman','tutor@tutormela.local','tutor'],['Tutormela Admin','admin@tutormela.local','admin']]) db.prepare('INSERT INTO users(name,email,password,role) VALUES(?,?,?,?)').run(name,email,hash('Tutormela2026!'),role);
 seeds.forEach((s,i)=>{let uid=2;if(i){uid=Number(db.prepare('INSERT INTO users(name,email,password,role) VALUES(?,?,?,?)').run(s[0],`sample${i}@tutormela.local`,hash(randomBytes(32).toString('hex')),'tutor').lastInsertRowid)}const [name,initials,university,education,district,areas,subjects,classes,fee,modes,experience,time,days,aboutEn,aboutBn]=s;db.prepare('INSERT INTO profiles(user_id,body,status,sample) VALUES(?,?,?,1)').run(uid,JSON.stringify({name,initials,university,education,district,areas,subjects,classes,fee,modes,experience,time,days,aboutEn,aboutBn,medium:'Bangla & English',available:true,photo:''}), 'approved')});
}
db.exec('CREATE INDEX IF NOT EXISTS profiles_status ON profiles(status); CREATE INDEX IF NOT EXISTS requests_student ON requests(user_id); CREATE INDEX IF NOT EXISTS requests_profile ON requests(profile_id);');
const profile=p=>({...JSON.parse(p.body),id:p.id,status:p.status,reason:p.reason,sample:!!p.sample});
function fail(status,message){throw Object.assign(new Error(message),{status})}
function text(v,max=200){return typeof v==='string'?v.trim().slice(0,max):''}
function validateProfile(p){
 const b={name:text(p.name,80),university:text(p.university),education:text(p.education),district:text(p.district),areas:text(p.areas),fee:Number(p.fee),experience:text(p.experience,60),time:text(p.time,40),aboutEn:text(p.aboutEn,3000),aboutBn:text(p.aboutBn,3000),medium:text(p.medium,60),available:p.available!==false};
 for(const [k,allowed] of [['subjects',subjects],['classes',classes],['modes',modes],['days',days]]){b[k]=Array.isArray(p[k])?[...new Set(p[k])].filter(x=>allowed.includes(x)):[];if(!b[k].length)fail(400,`Please select ${k}.`)}
 if(!b.name||!b.university||!b.education||!districts.includes(b.district)||!b.areas||!b.aboutEn||!b.aboutBn||!['Morning','Afternoon','Evening','Flexible'].includes(b.time)||!['Bangla medium','English medium','Bangla & English'].includes(b.medium)||!Number.isInteger(b.fee)||b.fee<500||b.fee>100000)fail(400,'Complete all required fields. Monthly fees must be between ৳500 and ৳100,000.');
 b.photo='';if(p.photo){if(typeof p.photo!=='string'||p.photo.length>2800000||!/^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/]+=*$/.test(p.photo))fail(400,'Use a PNG, JPEG or WebP photo under 2 MB.');const raw=Buffer.from(p.photo.split(',')[1],'base64');const valid=(raw[0]===255&&raw[1]===216)||(raw.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])))||(raw.toString('ascii',0,4)==='RIFF'&&raw.toString('ascii',8,12)==='WEBP');if(!valid)fail(400,'The photo file is not a supported image.');b.photo=p.photo}return b;
}
const limits=new Map();
const server=http.createServer(async(req,res)=>{
 const headers={'Content-Type':'application/json','Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'same-origin'};
 const send=(status,data)=>{res.writeHead(status,headers);res.end(JSON.stringify(data))};
 try{
 const url=new URL(req.url,'http://localhost');const path=url.pathname;
 if(!path.startsWith('/api/')){
  if(process.env.NODE_ENV==='production'){const file=resolve(root,'dist',path.slice(1)||'index.html');if(!file.startsWith(resolve(root,'dist')+'/'))fail(404,'Not found');const target=existsSync(file)?file:resolve(root,'dist/index.html');const mime={'.html':'text/html','.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml','.png':'image/png','.woff2':'font/woff2'};res.writeHead(200,{'Content-Type':mime[extname(target)]||'application/octet-stream','X-Content-Type-Options':'nosniff','Content-Security-Policy':"default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; base-uri 'self'; frame-ancestors 'none'"});res.end(readFileSync(target));return}fail(404,'Not found')
 }
 if(!['GET','HEAD'].includes(req.method)){const origin=req.headers.origin;if(origin&&new URL(origin).host!==req.headers.host)fail(403,'Cross-site request denied.');if(!req.headers['content-type']?.startsWith('application/json'))fail(415,'JSON required.')}
 const token=req.headers.cookie?.split(';').map(x=>x.trim()).find(x=>x.startsWith('tm_session='))?.slice(11);
 const tokenHash=token&&createHash('sha256').update(token).digest('hex');const session=tokenHash&&db.prepare('SELECT * FROM sessions WHERE token=? AND expires>?').get(tokenHash,Date.now());const user=session&&db.prepare('SELECT * FROM users WHERE id=?').get(session.user_id);
 const auth=role=>{if(!user)fail(401,'Please sign in to continue.');if(role&&user.role!==role)fail(403,'You do not have permission for this action.')};
 let body={};if(!['GET','HEAD'].includes(req.method)){let raw='';for await(const chunk of req){raw+=chunk;if(Buffer.byteLength(raw)>3000000)fail(413,'Upload is too large.')}try{body=JSON.parse(raw||'{}')}catch{fail(400,'Invalid request.')}}
 if(path==='/api/catalog')return send(200,{districts,subjects,classes,modes,days,demo});
 if(path==='/api/me')return send(200,{user:safeUser(user)||null});
 if(path==='/api/auth/login'||path==='/api/auth/register'){
  if(req.method!=='POST')fail(405,'Method not allowed');const key=req.socket.remoteAddress;let l=limits.get(key);if(!l||l.until<Date.now()){l={count:0,until:Date.now()+600000};limits.set(key,l)}if(++l.count>30)fail(429,'Too many attempts. Please try again in 10 minutes.');
  const email=text(body.email,200).toLowerCase(),password=typeof body.password==='string'?body.password:'';if(password.length>128)fail(400,'Password is too long.');let u;
  if(path.endsWith('register')){const name=text(body.name,80),role=body.role;if(!name||!/^\S+@\S+\.\S+$/.test(email)||password.length<10||!['student','tutor'].includes(role))fail(400,'Enter your name, valid email, and a password of at least 10 characters.');if(db.prepare('SELECT id FROM users WHERE email=?').get(email))fail(409,'An account with this email already exists.');const id=db.prepare('INSERT INTO users(name,email,password,role) VALUES(?,?,?,?)').run(name,email,hash(password),role).lastInsertRowid;u=db.prepare('SELECT * FROM users WHERE id=?').get(id)}else{u=db.prepare('SELECT * FROM users WHERE email=?').get(email);if(!u||!verify(password,u.password))fail(401,'Email or password is incorrect.')}
  const t=randomBytes(32).toString('hex');db.prepare('INSERT INTO sessions(token,user_id,expires) VALUES(?,?,?)').run(createHash('sha256').update(t).digest('hex'),u.id,Date.now()+7*86400000);headers['Set-Cookie']=`tm_session=${t}; HttpOnly; SameSite=Lax; Path=/; Max-Age=604800${process.env.COOKIE_SECURE==='1'?'; Secure':''}`;return send(200,{user:safeUser(u)})
 }
 if(path==='/api/auth/logout'&&req.method==='POST'){if(tokenHash)db.prepare('DELETE FROM sessions WHERE token=?').run(tokenHash);headers['Set-Cookie']='tm_session=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0';return send(200,{ok:true})}
 if(path==='/api/profiles'&&req.method==='GET')return send(200,db.prepare("SELECT * FROM profiles WHERE status='approved'").all().map(profile));
 if(path==='/api/profile'&&req.method==='GET'){auth('tutor');const p=db.prepare('SELECT * FROM profiles WHERE user_id=?').get(user.id);return send(200,p?profile(p):null)}
 if(path==='/api/profile'&&req.method==='PUT'){auth('tutor');const b=validateProfile(body);db.prepare("INSERT INTO profiles(user_id,body,status) VALUES(?,?,'pending') ON CONFLICT(user_id) DO UPDATE SET body=excluded.body,status='pending',reason='',sample=0").run(user.id,JSON.stringify(b));return send(200,profile(db.prepare('SELECT * FROM profiles WHERE user_id=?').get(user.id)))}
 if(path==='/api/saved'){auth('student');if(req.method==='GET')return send(200,db.prepare("SELECT p.* FROM profiles p JOIN saved s ON s.profile_id=p.id WHERE s.user_id=? AND p.status='approved'").all(user.id).map(profile));if(req.method==='POST'||req.method==='DELETE'){const id=Number(body.profileId);if(req.method==='POST'){if(!db.prepare("SELECT id FROM profiles WHERE id=? AND status='approved'").get(id))fail(404,'Tutor is no longer available.');db.prepare('INSERT OR IGNORE INTO saved(user_id,profile_id) VALUES(?,?)').run(user.id,id)}else db.prepare('DELETE FROM saved WHERE user_id=? AND profile_id=?').run(user.id,id);return send(200,{ok:true})}}
 if(path==='/api/requests'&&req.method==='POST'){auth('student');const p=db.prepare("SELECT * FROM profiles WHERE id=? AND status='approved'").get(Number(body.profileId));if(!p||!JSON.parse(p.body).available)fail(404,'Tutor is not accepting requests.');const b={studentName:text(body.studentName,80),className:text(body.className,80),subject:text(body.subject,80),mode:text(body.mode,80),message:text(body.message,1500),contact:text(body.contact,160)};if(!b.studentName||!b.className||!b.subject||!b.mode||!b.message||!b.contact)fail(400,'Please complete all request fields.');const pp=JSON.parse(p.body);if(!pp.classes.includes(b.className)||!pp.subjects.includes(b.subject)||!pp.modes.includes(b.mode))fail(400,'Choose this tutor’s available class, subject and teaching mode.');if(db.prepare("SELECT id FROM requests WHERE user_id=? AND profile_id=? AND status='pending'").get(user.id,p.id))fail(409,'You already have a pending request with this tutor.');db.prepare('INSERT INTO requests(user_id,profile_id,body) VALUES(?,?,?)').run(user.id,p.id,JSON.stringify(b));return send(201,{ok:true})}
 if(path==='/api/requests'&&req.method==='GET'){auth();let rows;if(user.role==='student')rows=db.prepare('SELECT r.*,p.body AS tutor FROM requests r JOIN profiles p ON p.id=r.profile_id WHERE r.user_id=? ORDER BY r.id DESC').all(user.id);else if(user.role==='tutor')rows=db.prepare('SELECT r.*,p.body AS tutor FROM requests r JOIN profiles p ON p.id=r.profile_id WHERE p.user_id=? ORDER BY r.id DESC').all(user.id);else fail(403,'Not permitted');return send(200,rows.map(r=>({...JSON.parse(r.body),id:r.id,status:r.status,created:r.created,tutorName:JSON.parse(r.tutor).name})))}
 if(/^\/api\/requests\/\d+$/.test(path)&&req.method==='PATCH'){auth();const id=Number(path.split('/').pop());const r=db.prepare('SELECT r.*,p.user_id AS owner FROM requests r JOIN profiles p ON p.id=r.profile_id WHERE r.id=?').get(id);if(!r)fail(404,'Request not found.');if(user.role==='student'&&r.user_id===user.id&&body.status==='cancelled'||user.role==='tutor'&&r.owner===user.id&&['accepted','declined'].includes(body.status)){if(r.status!=='pending')fail(409,'This request has already been resolved.');db.prepare('UPDATE requests SET status=? WHERE id=?').run(body.status,id);return send(200,{ok:true})}fail(403,'Not permitted')}
 if(path==='/api/admin/profiles'&&req.method==='GET'){auth('admin');return send(200,db.prepare('SELECT * FROM profiles ORDER BY id DESC').all().map(profile))}
 if(/^\/api\/admin\/profiles\/\d+$/.test(path)&&req.method==='PATCH'){auth('admin');if(!['approved','rejected'].includes(body.status))fail(400,'Invalid status.');const reason=text(body.reason,600);if(body.status==='rejected'&&!reason)fail(400,'Please provide a reason for the tutor.');const result=db.prepare('UPDATE profiles SET status=?,reason=? WHERE id=?').run(body.status,reason,Number(path.split('/').pop()));if(!result.changes)fail(404,'Profile not found.');return send(200,{ok:true})}
 fail(404,'Not found');
 }catch(e){if(!e.status)console.error(e);send(e.status||500,{error:e.status?e.message:'Something went wrong. Please try again.'})}
});
server.listen(Number(process.env.PORT||3001),'127.0.0.1',()=>console.log(`Tutormela API: http://localhost:${process.env.PORT||3001}`));
