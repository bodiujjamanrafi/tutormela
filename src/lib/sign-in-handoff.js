import {postLoginRoute} from './navigation.js'
// Only call after the server has established a verified website account.
export async function handoffSignIn({user,onAuthenticated,navigate,hydrate,afterSignIn,onError}){
 if(!user?.id||!['student','tutor','admin'].includes(user.role))throw new Error('Your signed-in account could not be verified.')
 onAuthenticated(user)
 // Ancillary profile/request failures must never keep a verified user on the login screen.
 navigate(postLoginRoute(user.role))
 try{await hydrate(user)}catch(error){onError(error)}
 if(afterSignIn){try{await afterSignIn(user)}catch(error){onError(error)}}
}
