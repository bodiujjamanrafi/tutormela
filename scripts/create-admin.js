import {createInterface} from 'node:readline/promises';
import {stdin,stdout} from 'node:process';
import {DatabaseSync} from 'node:sqlite';
import {randomBytes,scryptSync} from 'node:crypto';
import {mkdirSync} from 'node:fs';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const rl=createInterface({input:stdin,output:stdout});
try{const email=(await rl.question('Administrator email: ')).trim().toLowerCase();if(!/^\S+@\S+\.\S+$/.test(email))throw new Error('A valid email is required.');const name=(await rl.question('Administrator name: ')).trim();if(!name)throw new Error('Name is required.');mkdirSync(resolve(root,'data'),{recursive:true});const db=new DatabaseSync(resolve(root,'data/tutormela.sqlite'));if(!db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='users'").get())throw new Error('Start the production server once to initialize the database, then run this command again.');if(db.prepare('SELECT id FROM users WHERE email=?').get(email))throw new Error('Account already exists.');const password=randomBytes(18).toString('base64url'),salt=randomBytes(16).toString('hex');db.prepare('INSERT INTO users(name,email,password,role) VALUES(?,?,?,?)').run(name,email,salt+':'+scryptSync(password,salt,64).toString('hex'),'admin');console.log('\nAdministrator created. Store this password securely:\n'+password);db.close()}catch(e){console.error(e.message);process.exitCode=1}finally{rl.close()}
