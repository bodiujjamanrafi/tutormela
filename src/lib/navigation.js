export const initialRoute=hash=>{const route=hash.replace(/^#\/?/,'');return !route||route==='feed'?'browse':route}
export const postLoginRoute=role=>role==='student'?'browse':'dashboard'

export const tutorProfileLink=(profileId,postId)=>`tutor/${profileId}${postId?'?post='+encodeURIComponent(postId):''}`
