// Call only after the custom code was consumed and its email/user binding checked.
// The generated Supabase token stays on the server; only the finished user session is returned.
export async function createVerifiedEmailSession(admin,auth,account){
 const generated=await admin.generateLink({type:'magiclink',email:account.email})
 if(generated.error||generated.data?.user?.id!==account.id||!generated.data?.properties?.hashed_token)throw new Error('Session generation unavailable')
 const login=await auth.verifyOtp({token_hash:generated.data.properties.hashed_token,type:'email'})
 if(login.error||!login.data?.session||login.data.user?.id!==account.id)throw new Error('Verified sign-in unavailable')
 return login.data.session
}

// Validate existing credentials before sending a code, rather than asking again afterwards.
export async function checkInitialPassword(auth,email,password){
 const result=await auth.signInWithPassword({email,password})
 if(result.error?.code==='email_not_confirmed')return true
 if(result.error)return false
 // This temporary password check must not leave a spare session behind.
 const signedOut=await auth.signOut({scope:'local'})
 if(signedOut.error)throw new Error('Password check unavailable')
 return true
}
