import {initializeApp,getApp,getApps} from 'firebase/app'
import {getAuth,setPersistence,inMemoryPersistence,GoogleAuthProvider,signInWithPopup,signOut} from 'firebase/auth'
const firebaseConfig={
 apiKey:import.meta.env.VITE_FIREBASE_API_KEY,
 authDomain:import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
 projectId:import.meta.env.VITE_FIREBASE_PROJECT_ID,
 storageBucket:import.meta.env.VITE_FIREBASE_STORAGE_BUCKET,
 messagingSenderId:import.meta.env.VITE_FIREBASE_MESSAGING_SENDER_ID,
 appId:import.meta.env.VITE_FIREBASE_APP_ID,
}
let ready
export function prepareFirebaseAuth(){
 if(!ready)ready=(async()=>{if(!firebaseConfig.apiKey||!firebaseConfig.authDomain||firebaseConfig.projectId!=='tutormela')throw new Error('Google sign-in is not configured yet.');const app=getApps().length?getApp():initializeApp(firebaseConfig),auth=getAuth(app);await setPersistence(auth,inMemoryPersistence);return auth})().catch(e=>{ready=null;throw e})
 return ready
}
export async function googleCredential(hashedNonce){
 const auth=await prepareFirebaseAuth(),provider=new GoogleAuthProvider()
 provider.setCustomParameters({prompt:'select_account',nonce:hashedNonce})
 const result=await signInWithPopup(auth,provider),credential=GoogleAuthProvider.credentialFromResult(result)
 if(!credential?.idToken)throw new Error('Google did not return a sign-in token. Please try again.')
 return {idToken:credential.idToken,accessToken:credential.accessToken}
}
export async function clearFirebaseSignIn(){if(ready){try{await signOut(await ready)}catch{/* The Supabase session remains the website's only persisted session. */}}}
