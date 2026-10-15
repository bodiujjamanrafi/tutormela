export function matchesTutorPost(post,filters){
 const p=post.profile,q=String(filters.q||'').toLowerCase()
 return (!filters.district||p.district===filters.district)&&(!filters.districts||filters.districts.includes(p.district))&&(!filters.subject||p.subjects.includes(filters.subject)||p.subjects.includes('All subjects'))&&(!filters.className||p.classes.includes(filters.className))&&p.fee<=Number(filters.budget??100000)&&(!filters.mode||p.modes.includes(filters.mode))&&(!filters.medium||p.medium===filters.medium||p.medium==='Bangla & English')&&(!filters.available||p.available)&&(!q||[p.name,p.university,p.district,p.areas,...p.subjects,post.body].join(' ').toLowerCase().includes(q))
}
export function sortTutorPosts(posts,sort){return [...posts].sort((a,b)=>(sort==='low'?a.profile.fee-b.profile.fee:sort==='high'?b.profile.fee-a.profile.fee:0)||b.created_at.localeCompare(a.created_at)||String(b.id||b.profile.id).localeCompare(String(a.id||a.profile.id)))}
