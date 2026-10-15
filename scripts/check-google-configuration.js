import {privateEnvironment} from './lib/smtp-config.js'
const env=privateEnvironment()
try{
 const configResponse=await fetch('https://identitytoolkit.googleapis.com/v1/projects?key='+encodeURIComponent(env.VITE_FIREBASE_API_KEY)),config=await configResponse.json()
 if(!configResponse.ok)throw new Error('Firebase public project configuration could not be verified.')
 const providerResponse=await fetch('https://identitytoolkit.googleapis.com/v1/accounts:createAuthUri?key='+encodeURIComponent(env.VITE_FIREBASE_API_KEY),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({providerId:'google.com',continueUri:'http://localhost:5173',customParameter:{nonce:'tutormela-readiness-check'}})}),provider=await providerResponse.json()
 const settingsResponse=await fetch(env.VITE_SUPABASE_URL+'/auth/v1/settings',{headers:{apikey:env.VITE_SUPABASE_PUBLISHABLE_KEY}}),settings=await settingsResponse.json()
 const ready={firebaseGoogleEnabled:providerResponse.ok&&!!provider.authUri,localhostAuthorized:config.authorizedDomains?.includes('localhost')===true,supabaseGoogleEnabled:settingsResponse.ok&&settings.external?.google===true}
 console.log(ready)
 if(!Object.values(ready).every(Boolean)){console.log('Finish the settings in FIREBASE_GOOGLE_SETUP.md, then run this check again.');process.exitCode=1}else console.log('Provider configuration checks passed. Complete a Google login in the browser to verify the full account flow.')
}catch{console.error('Google provider configuration could not be checked. No credentials were logged.');process.exitCode=1}
