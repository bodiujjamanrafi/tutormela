// Temporary, isolated preview state with client-side website persistence. Passwords are checked for input only and never retained.
const STORAGE_ACCOUNTS='tm_db_accounts',STORAGE_SESSION='tm_db_session',STORAGE_VIEWS='tm_db_views',STORAGE_REACTIONS='tm_db_reactions'
export function createDemoSession(){
 let state=null
 const accounts=new Map(),views=new Map(),reactions=new Map()
 const copy=v=>structuredClone(v),now=()=>new Date().toISOString()
 const loadStorage=()=>{
  try{
   if(typeof window==='undefined'||!window.localStorage)return
   const a=localStorage.getItem(STORAGE_ACCOUNTS);if(a){accounts.clear();for(const [k,v] of JSON.parse(a))accounts.set(k,v)}
   const v=localStorage.getItem(STORAGE_VIEWS);if(v){views.clear();for(const [k,s] of JSON.parse(v))views.set(k,new Set(s))}
   const r=localStorage.getItem(STORAGE_REACTIONS);if(r){reactions.clear();for(const [k,s] of JSON.parse(r))reactions.set(k,new Set(s))}
   const s=localStorage.getItem(STORAGE_SESSION);if(s&&accounts.has(s))state=accounts.get(s)
  }catch{}
 }
 const saveStorage=()=>{
  try{
   if(typeof window==='undefined'||!window.localStorage)return
   localStorage.setItem(STORAGE_ACCOUNTS,JSON.stringify([...accounts.entries()]))
   localStorage.setItem(STORAGE_VIEWS,JSON.stringify([...views.entries()].map(([k,s])=>[k,[...s]])))
   localStorage.setItem(STORAGE_REACTIONS,JSON.stringify([...reactions.entries()].map(([k,s])=>[k,[...s]])))
   if(state){const key=state.user.role+':'+state.user.email.toLowerCase();localStorage.setItem(STORAGE_SESSION,key)}else localStorage.removeItem(STORAGE_SESSION)
  }catch{}
 }
 loadStorage()
 const profiles=()=>[...accounts.values()].filter(a=>a.profile?.feed_visible).map(a=>a.profile)
 const posts=()=>[...accounts.values()].flatMap(a=>a.statuses.filter(p=>!p.withdrawn_at&&a.profile?.feed_visible).map(p=>({...p,profile:a.profile,owner:state?a.user.id===state.user.id:false,reactions:reactions.get(p.id)?.size||0,reacted:state?reactions.get(p.id)?.has(state.user.id)||false:false}))).sort((a,b)=>b.created_at.localeCompare(a.created_at)||b.id.localeCompare(a.id))
 const findProfile=id=>profiles().find(p=>p.id===id)
 return {
  get active(){return !!state},
  get hasPosts(){return posts().length>0},
  get publicProfiles(){return copy(profiles())},
  getFeedPosts(before,id){let rows=posts();if(before)rows=rows.filter(p=>p.created_at<before||(p.created_at===before&&p.id<id));return copy(rows.slice(0,20))},
  handles(path,method){return path==='/auth/demo'||!!state&&!(path==='/catalog'||path==='/profiles'&&method==='GET')},
  request(path,method='GET',body={}){
   if(path==='/auth/demo'){
    if(!['tutor','student'].includes(body.role))throw new Error('Choose a student or tutor demo.')
    if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(body.email||'')||!body.password)throw new Error('Enter a test email and password.')
    const key=body.role+':'+body.email.toLowerCase()
    state=accounts.get(key)
    if(!state){
     const name=body.name?.trim()||(body.role==='tutor'?'Demo Tutor':'Demo Student')
     const user={id:crypto.randomUUID(),name,email:body.email,role:body.role,demo:true,onboarding_complete:true,preferences:{},photo:'',district:'',phone:'',learning_goals:''}
     state={user,profile:body.role==='tutor'?{id:crypto.randomUUID(),user_id:user.id,name,university:'',education:'',district:'Dhaka',areas:'',subjects:[],classes:[],fee:5000,modes:[],experience:'',time:'Evening',days:[],aboutEn:'',aboutBn:'',medium:'Bangla & English',available:true,photo:'',status:'draft',feed_visible:false,reason:'',created:now(),updated_at:now()}:null,statuses:[],saved:[],requests:[]}
     accounts.set(key,state)
    }
    saveStorage()
    return {user:copy(state.user)}
   }
   if(!state)throw new Error('Start a demo session first.')
   if(path==='/auth/logout'){state=null;saveStorage();return {ok:true}}
   if(path==='/me')return {user:copy(state.user)}
   if(path==='/preferences'&&method==='PUT'){state.user.preferences=copy(body);saveStorage();return {ok:true}}
   if(path==='/account/email'){if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(body.email||''))throw new Error('Enter a valid email.');state.user.email=body.email;saveStorage();return {user:copy(state.user)}}
   if(path==='/auth/password'||path==='/account/password')return {ok:true}
   if(path==='/account'&&method==='PUT'){
    for(const key of ['name','photo','district','phone','learning_goals'])if(body[key]!==undefined)state.user[key]=body[key]
    if(body.photo!==undefined&&state.profile)state.profile.photo=body.photo
    saveStorage()
    return {user:copy(state.user)}
   }
   if(path==='/profile/hide'){if(!state.profile)throw new Error('Only tutors can share teaching profiles.');state.profile.feed_visible=false;state.profile.updated_at=now();saveStorage();return {ok:true}}
   if(path==='/profile'){
    if(state.user.role!=='tutor')throw new Error('Only the tutor demo can edit a teaching profile.')
    if(method==='PUT'){
     if(!body.draft&&!body.consent)throw new Error('Confirm sharing your details publicly.')
     const fields=['name','university','education','district','areas','subjects','classes','fee','modes','experience','time','days','aboutEn','aboutBn','medium','available','photo']
     for(const key of fields)if(body[key]!==undefined)state.profile[key]=copy(body[key])
     if(body.photo!==undefined)state.user.photo=body.photo
     if(body.name!==undefined)state.user.name=body.name
     Object.assign(state.profile,{status:body.draft?'draft':'pending',feed_visible:!body.draft,updated_at:now()})
     if(!body.draft){
      const existing=state.statuses.find(p=>p.kind==='identity')
      const intro=(state.profile.aboutEn||state.profile.aboutBn||'Available for tuition').trim()
      const subj=(state.profile.subjects||[]).join(', ')
      const text=[intro,subj,state.profile.district].filter(Boolean).join(' · ')
      if(existing){existing.body=text;existing.withdrawn_at=null}
      else state.statuses.unshift({id:crypto.randomUUID(),profile_id:state.profile.id,kind:'identity',body:text,created_at:now(),withdrawn_at:null})
     }
     saveStorage()
    }
    return copy(state.profile)
   }
   if(path.startsWith('/feed')&&method==='GET'){const params=new URLSearchParams(path.split('?')[1]);let rows=posts();const before=params.get('before'),id=params.get('id');if(before)rows=rows.filter(p=>p.created_at<before||(p.created_at===before&&p.id<id));return copy(rows.slice(0,20))}
   if(/^\/feed\/[^/]+\/reaction$/.test(path)){const post=posts().find(p=>p.id===path.split('/')[2]);if(!post||post.owner)throw new Error('React to another tutor’s shared post.');const set=reactions.get(post.id)||new Set();if(body.reacted)set.add(state.user.id);else set.delete(state.user.id);reactions.set(post.id,set);saveStorage();return {count:set.size}}
   if(path==='/views'){const post=body.kind==='post'?posts().find(p=>p.id===body.target):null;const p=post?.profile||(body.kind==='profile'?findProfile(body.target):null);if(p&&p.user_id!==state.user.id){const key=body.kind+':'+body.target;const set=views.get(key)||new Set();set.add(state.user.id);views.set(key,set);saveStorage()}return {ok:true}}
   if(path==='/analytics')return {profileViews:views.get('profile:'+state.profile?.id)?.size||0,posts:copy(state.statuses.map(p=>({...p,views:views.get('post:'+p.id)?.size||0,reactions:reactions.get(p.id)?.size||0})))}
   if(path.startsWith('/statuses?')){const id=new URLSearchParams(path.split('?')[1]).get('profile');return id===state.profile?.id?copy(state.statuses):[]}
   if(path==='/statuses'&&method==='POST'){
    if(state.user.role!=='tutor'||!state.profile)throw new Error('Only tutors can post updates.')
    const text=body.body?.trim()||''
    if(!body.consent||text.length<15||text.length>1200)throw new Error('Write 15–1,200 characters and confirm sharing consent.')
    state.profile.feed_visible=true
    state.profile.updated_at=now()
    state.statuses.unshift({id:crypto.randomUUID(),profile_id:state.profile.id,kind:'update',body:text,created_at:now(),withdrawn_at:null})
    saveStorage()
    return {ok:true}
   }
   if(path.startsWith('/statuses/')){const row=state.statuses.find(p=>p.id===path.split('/').pop());if(!row)throw new Error('This post does not belong to you.');if(method==='PUT'){if((body.body?.trim().length||0)<15||body.body.length>1200)throw new Error('Write 15–1,200 characters.');row.body=body.body.trim()}else if(method==='PATCH')row.withdrawn_at=body.visible?null:now();else throw new Error('This action is unavailable.');saveStorage();return {ok:true}}
   if(path==='/saved'){if(state.user.role!=='student')throw new Error('Saving tutors is available in the student demo.');if(method==='GET')return copy(state.saved);if(method==='POST'&&!state.saved.includes(body.profileId))state.saved.push(body.profileId);if(method==='DELETE')state.saved=state.saved.filter(id=>id!==body.profileId);saveStorage();return {ok:true}}
   if(path==='/requests'){if(method==='GET')return copy(state.requests);throw new Error('Contact requests are not sent in demo mode. Use a real account to contact a tutor.')}
   throw new Error('This action needs a real account. Sign out of the demo and use Sign in.')
  }
 }
}
