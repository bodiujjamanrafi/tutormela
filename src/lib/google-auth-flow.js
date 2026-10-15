export function googleError(error){
 const code=error?.code||''
 if(code==='auth/popup-closed-by-user'||code==='auth/cancelled-popup-request')return 'Google sign-in was cancelled. You can try again.'
 if(code==='auth/popup-blocked')return 'Allow pop-ups for Tutormela, then try Google sign-in again.'
 if(code==='auth/unauthorized-domain')return 'Google sign-in is not authorized for this address. Use localhost:5173 for local testing, or add this domain in Firebase Authentication settings.'
 if(code==='auth/operation-not-allowed')return 'Google sign-in needs to be enabled in Firebase Authentication.'
 if(code==='auth/account-exists-with-different-credential')return 'This email already uses another sign-in method. Sign in with that method first.'
 if(code==='auth/network-request-failed')return 'Google could not connect. Check your connection and try again.'
 return error?.message||'Google sign-in could not be completed. Please try again.'
}
export async function firebaseGoogleSession({getCredential,exchange,verifyUser,clear,checkProvider,cryptoApi=globalThis.crypto}){
 const bytes=cryptoApi.getRandomValues(new Uint8Array(32)),nonce=Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join('')
 const hash=new Uint8Array(await cryptoApi.subtle.digest('SHA-256',new TextEncoder().encode(nonce))),hashedNonce=Array.from(hash,b=>b.toString(16).padStart(2,'0')).join('')
 try{
  if(checkProvider)await checkProvider()
  const credential=await getCredential(hashedNonce)
  if(!credential?.idToken)throw new Error('Google did not return a sign-in token.')
  const result=await exchange({provider:'google',token:credential.idToken,nonce,...(credential.accessToken?{access_token:credential.accessToken}:{})})
  if(result.error){if(['provider_disabled','validation_failed'].includes(result.error.code)||/not enabled|unsupported provider/i.test(result.error.message||''))throw new Error('Google is connected to Firebase. Its secure connection to Tutormela still needs activation.');throw new Error('Google could not securely sign you in. Please try again.')}
  if(!result.data?.session?.access_token||!result.data?.user?.id)throw new Error('Google did not create a website session. Please try again.')
  if(!verifyUser)throw new Error('Your Google account could not be verified.')
  const verified=await verifyUser(result.data.session.access_token),user=verified.data?.user
  if(verified.error||!user||user.id!==result.data.user.id||!user.email||!user.email_confirmed_at||!user.identities?.some(identity=>identity.provider==='google'))throw new Error('Your Google account could not be verified. Please sign in again.')
  return {...result.data,user}
 }catch(error){throw new Error(googleError(error))}finally{await clear()}
}
