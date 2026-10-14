import {readFileSync,readdirSync,existsSync} from 'node:fs'
import {join,relative} from 'node:path'
import assert from 'node:assert/strict'
import {privateEnvironment,projectRoot} from './lib/smtp-config.js'
const env=privateEnvironment()
const privateKeys=Object.keys(env).filter(k=>/PASSWORD|SECRET|ACCESS_TOKEN/i.test(k))
assert.ok(!privateKeys.some(k=>k.startsWith('VITE_')),'Private credentials must never use a VITE_ prefix.')
const values=privateKeys.flatMap(k=>[env[k],/password/i.test(k)?env[k]?.replace(/\s/g,''):null]).filter(v=>v&&v.length>=8)
function scan(path){if(!existsSync(path))return;for(const item of readdirSync(path,{withFileTypes:true})){const file=join(path,item.name);if(item.isDirectory())scan(file);else if(item.isFile()){const bytes=readFileSync(file);assert.ok(!values.some(value=>bytes.includes(Buffer.from(value))),`Private credential found in public file: ${relative(projectRoot,file)}`)}}}
for(const dir of ['src','public','dist'])scan(join(projectRoot,dir))
console.log('Private SMTP, OTP-signing and deployment credentials are absent from website source assets and production build files.')
