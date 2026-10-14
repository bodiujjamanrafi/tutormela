// Both first-use confirmation and later sign-ins finish in the same four-digit form.
export async function passwordSignIn({auth,codeEnabled,sendCode,confirmEmail,currentUser},{email,password}){
 const address=String(email||'').trim()
 const result=await auth.signInWithPassword({email:address,password})
 if(result.error?.code==='email_not_confirmed')return confirmEmail({email:address,password})
 if(result.error)throw new Error(result.error.message||'Sign-in could not be completed.')
 if(await codeEnabled()){
  try{const sent=await sendCode();if(!sent?.sent)throw new Error('The verification email was not sent. Please try again.');return {verificationRequired:true,email:address}}
  catch(error){return {verificationRequired:true,email:address,deliveryError:error.message}}
 }
 return {user:await currentUser()}
}
export function isRealEmailAuth(path){return ['/auth/login','/auth/register','/auth/social','/auth/reset','/auth/code/send','/auth/code/verify'].includes(path)}
