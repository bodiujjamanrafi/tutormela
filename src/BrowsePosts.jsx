import {useState,useEffect} from 'react'
import {api} from './lib/data.js'
export default function BrowsePosts({filters,sort,user,renderPost,onTotal}){
 const [response,setResponse]=useState({key:'',data:null,error:''}),[page,setPage]=useState(1),[retry,setRetry]=useState(0)
 const searchKey=JSON.stringify({filters,sort}),[activeKey,setActiveKey]=useState(searchKey)
 const currentPage=activeKey===searchKey?page:1,requestKey=JSON.stringify([searchKey,currentPage,user?.id||'',retry])
 useEffect(()=>{let active=true;const query=JSON.parse(searchKey);api('/browse-posts','POST',{...query,page:currentPage}).then(result=>{if(active){setResponse({key:requestKey,data:result,error:''});onTotal(result.total)}}).catch(e=>{if(active)setResponse({key:requestKey,data:null,error:e.message})});return()=>{active=false}},[searchKey,currentPage,requestKey,onTotal])
 function changePage(next){setActiveKey(searchKey);setPage(next);document.getElementById('results')?.scrollIntoView({behavior:'smooth',block:'start'})}
 if(response.key!==requestKey)return <div className="browse-post-state" role="status">Loading tutor profiles and updates…</div>
 const {data,error}=response
 if(error)return <div className="browse-post-state" role="alert"><h3>We couldn’t load tutor posts</h3><p>{error}</p><button className="btn secondary" onClick={()=>setRetry(n=>n+1)}>Try again</button></div>
 if(!data?.items?.length)return <div className="browse-post-state"><h3>No matching posts yet</h3><p>Try another district, subject or budget. Tutor profiles and updates appear here when shared.</p></div>
 return <>{data.setupPending&&<p className="form-note">Showing existing tutor profiles and updates while the feed upgrade is being completed.</p>}<div className="tutor-grid unified-post-grid">{data.items.map(post=>renderPost(post))}</div><div className="pagination"><span>Showing {(currentPage-1)*6+1}–{Math.min(currentPage*6,data.total)} of {data.total} posts</span><div><button className="page-arrow" disabled={currentPage===1} onClick={()=>changePage(currentPage-1)} aria-label="Previous page">←</button><span className="current-page">{currentPage}</span><button className="page-arrow" disabled={currentPage*6>=data.total} onClick={()=>changePage(currentPage+1)} aria-label="Next page">→</button></div></div></>
}
