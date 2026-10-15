import {useEffect,useState} from 'react'
import {api} from './lib/data.js'
export default function TutorProfileRoute({route,renderProfile,onBrowse}){
 const [state,setState]=useState({key:'',profile:null,error:''}),[retry,setRetry]=useState(0)
 const part=route.slice('tutor/'.length),[id,search='']=part.split('?'),postId=new URLSearchParams(search).get('post'),key=JSON.stringify([id,postId])
 useEffect(()=>{let active=true;api('/tutor-page','GET',{profileId:id,postId}).then(profile=>{if(profile&&profile.id!==id)throw new Error('This profile could not be verified.');if(active)setState({key,profile,error:''})}).catch(e=>{if(active)setState({key,profile:null,error:e.message})});return()=>{active=false}},[id,postId,key,retry])
 if(state.key!==key)return <div className="panel" role="status">Loading the selected tutor’s profile…</div>
 if(state.error)return <div className="panel" role="alert"><h2>We couldn’t open this tutor</h2><p>{state.error}</p><button className="btn secondary" onClick={()=>setRetry(n=>n+1)}>Try again</button></div>
 if(!state.profile)return <div className="empty"><h2>This profile isn’t available</h2><p>The selected tutor or post is no longer publicly listed.</p><button className="btn primary" onClick={onBrowse}>Browse tutors</button></div>
 return renderProfile(state.profile)
}
