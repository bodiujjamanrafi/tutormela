import { useState, useRef, useEffect, useId } from 'react'
import { divisions, localizedDistrict, localizedDivision } from './assets/maps/geography.js'
import './Hero.css'
import './assets/hero/background.css'

function Mark({name,size=20}) {
 const paths={learn:'M3 8c3-1 6 0 9 2 3-2 6-3 9-2v12c-3-1-6 0-9 2-3-2-6-3-9-2V8m9 2v12M8 4l4-2 4 2-4 2-4-2',pin:'M19 10c0 5-7 11-7 11S5 15 5 10a7 7 0 1 1 14 0zm-4 0a3 3 0 1 1-6 0 3 3 0 0 1 6 0',arrow:'M4 12h16m-6-6 6 6-6 6',plus:'M12 5v14M5 12h14',minus:'M5 12h14',expand:'M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5',reset:'M3 11a9 9 0 1 1 2 7M3 4v7h7',close:'m6 6 12 12M6 18 18 6'}
 return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={paths[name]}/></svg>
}
const palette=['#d9d2bc','#c5d2c0','#d3cbd7','#e3cfb7','#c4d3d4','#deccc7','#c9d1df','#d4d4ba']
const mapMatrix='matrix(1 -0.065 0.09 0.94 -29 30)'
function useGeometry(){
 const [data,setData]=useState([]),[error,setError]=useState(''),[retry,setRetry]=useState(0)
 useEffect(()=>{let active=true;setError('');import('./assets/maps/district-paths.json').then(m=>{if(active)setData(m.default)}).catch(()=>{if(active)setError('Map unavailable')});return()=>{active=false}},[retry])
 return {data,error,reload:()=>setRetry(r=>r+1)}
}
function DistrictMap({value,onChange,onExpand,expanded=false,lang='en'}) {
 const {data:districts,error:mapError,reload}=useGeometry()
 const [hovered,setHovered]=useState(''),[zoom,setZoom]=useState(1),[pan,setPan]=useState({x:0,y:0}),[labels,setLabels]=useState(true)
 const svgRef=useRef(null),drag=useRef(null),moved=useRef(false),mapId=useId().replace(/:/g,'')
 const pointers=useRef(new Map()),pinch=useRef(null)
 const tr=(en,bn)=>lang==='bn'?bn:en
 const nameOf=name=>localizedDistrict(name,lang)
 useEffect(()=>{
  let cancelled=false
  const fit=()=>{
   if(cancelled||!svgRef.current)return
   const paths=new Map([...svgRef.current.querySelectorAll('.map-district')].map(g=>[g.dataset.district,g.querySelector('.district-face')]))
   for(const text of svgRef.current.querySelectorAll('.map-labels text')){
    const path=paths.get(text.dataset.labelDistrict);if(!path)continue
    let size=lang==='bn'?14:12.5,fitConfirmed=false
    // Fit the complete name's bounding box into its own district, never a neighbour.
    while(size>.8){
     text.style.fontSize=`${size}px`
     const box=text.getBBox();let inside=true
     for(let x=0;x<=6&&inside;x++)for(let y=0;y<=4;y++){
      if(!path.isPointInFill(new DOMPoint(box.x-.4+(box.width+.8)*x/6,box.y-.4+(box.height+.8)*y/4))){inside=false;break}
     }
     if(inside){fitConfirmed=true;break}
     size*=.9
    }
    text.dataset.contained=String(fitConfirmed)
   }
  }
  fit();document.fonts.ready.then(fit)
  return()=>{cancelled=true}
 },[districts,lang,labels,value])
 const clamp=(n,min,max)=>Math.max(min,Math.min(max,n))
 const reset=()=>{setZoom(1);setPan({x:0,y:0})}
 const zoomTo=n=>{n=clamp(n,1,6);setZoom(n);setPan(p=>({x:clamp(p.x,-(320-320/n),320-320/n),y:clamp(p.y,-(325-325/n),325-325/n)}))}
 const choose=name=>{if(!moved.current){onChange(name);setHovered(name)}}
 // Gestures are bound to this SVG; the hero, marquee and page never scale.
 useEffect(()=>{
  const svg=svgRef.current;if(!svg)return
  const wheel=e=>{if(e.ctrlKey||e.metaKey){e.preventDefault();zoomTo(zoom*(e.deltaY>0?.92:1.08))}}
  svg.addEventListener('wheel',wheel,{passive:false})
  return()=>svg.removeEventListener('wheel',wheel)
 },[zoom])
 const onDown=e=>{
  moved.current=false;pointers.current.set(e.pointerId,{x:e.clientX,y:e.clientY});svgRef.current.setPointerCapture(e.pointerId)
  if(pointers.current.size===2){const [a,b]=[...pointers.current.values()];pinch.current={distance:Math.hypot(a.x-b.x,a.y-b.y),zoom};drag.current=null;moved.current=true}
  else if(zoom>1)drag.current={x:e.clientX,y:e.clientY,pan}
 }
 const onMove=e=>{
  if(!pointers.current.has(e.pointerId))return
  pointers.current.set(e.pointerId,{x:e.clientX,y:e.clientY})
  if(pinch.current&&pointers.current.size===2){const [a,b]=[...pointers.current.values()];zoomTo(pinch.current.zoom*Math.hypot(a.x-b.x,a.y-b.y)/Math.max(1,pinch.current.distance));moved.current=true;return}
  if(!drag.current)return;const d=drag.current;if(Math.abs(e.clientX-d.x)+Math.abs(e.clientY-d.y)>6)moved.current=true
  const r=svgRef.current.getBoundingClientRect();setPan({x:clamp(d.pan.x-(e.clientX-d.x)*640/(r.width*zoom),-(320-320/zoom),320-320/zoom),y:clamp(d.pan.y-(e.clientY-d.y)*650/(r.height*zoom),-(325-325/zoom),325-325/zoom)})
 }
 const onUp=e=>{
  if(!moved.current){const target=document.elementFromPoint(e.clientX,e.clientY)?.closest('[data-district]');if(target)choose(target.dataset.district)}
  pointers.current.delete(e.pointerId);if(pointers.current.size<2)pinch.current=null;drag.current=null
 }

 const active=hovered||value
 return <div className={`district-map ${expanded?'is-expanded':''}`} data-language={lang}>
  <div className="map-toolbar"><div className="map-title"><span className="map-kicker">{tr('EXPLORE BY DISTRICT','জেলা অনুযায়ী খুঁজুন')}</span><h2>{tr('Find tutors near you','আপনার এলাকার টিউটর খুঁজুন')}</h2></div><div className="map-top-actions"><button className={`map-label-toggle ${labels?'active':''}`} onClick={()=>setLabels(v=>!v)} aria-pressed={labels}>{tr('Aa','অআ')}<span>{tr('District names','জেলার নাম')}</span></button>{onExpand&&<button className="map-icon-button" onClick={onExpand} aria-label="Expand Bangladesh map"><Mark name="expand" size={18}/></button>}</div></div>
  <div className="map-canvas">
   {!districts.length&&<div className="map-loading" role="status">{mapError?<><p>{tr('The map could not load. Please try again.','মানচিত্র লোড হয়নি। আবার চেষ্টা করুন।')}</p><button onClick={reload}>{tr('Retry map','আবার চেষ্টা করুন')}</button></>:<><span className="map-loading-icon"/><p>{tr('Preparing the district map…','জেলার মানচিত্র লোড হচ্ছে…')}</p></>}</div>}
   <div className="map-north" aria-hidden="true"><span>{tr('N','উ')}</span><i/></div>
   <svg ref={svgRef} className="bangladesh-map" viewBox={`${320-320/zoom+pan.x} ${325-325/zoom+pan.y} ${640/zoom} ${650/zoom}`} aria-label="Interactive relief map of all 64 Bangladesh districts" role="group" onPointerDown={onDown} onPointerMove={onMove} onPointerUp={onUp} onPointerCancel={e=>{pointers.current.delete(e.pointerId);drag.current=null;pinch.current=null}} style={{touchAction:'none'}}>
    <defs>{districts.map((d,i)=><clipPath key={d.name} id={`${mapId}-label-${i}`} clipPathUnits="userSpaceOnUse"><path d={d.path} fillRule="evenodd" clipRule="evenodd"/></clipPath>)}<filter id={`${mapId}-shadow`} x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="3" dy="14" stdDeviation="8" floodColor="#38413c" floodOpacity=".15"/></filter></defs>
    <g transform={mapMatrix}>
     <g className="map-depth" transform="translate(0 10)" filter={`url(#${mapId}-shadow)`} aria-hidden="true">{districts.map(d=><path d={d.path} key={d.name} fill="#9caa99" stroke="#9caa99" strokeWidth="1.1" fillRule="evenodd"/>)}</g>
     <g className="map-mid-depth" transform="translate(0 5)" aria-hidden="true">{districts.map(d=><path d={d.path} key={d.name} fill="#b2bda9" stroke="#b2bda9" strokeWidth=".6" fillRule="evenodd"/>)}</g>
     {districts.map(d=><g key={d.name} className={`map-district ${value===d.name?'selected':''} ${hovered===d.name?'hovered':''}`} data-district={d.name} role="button" tabIndex="0" aria-label={tr(`Find tutors in ${d.name}`,`${nameOf(d.name)} জেলার টিউটর খুঁজুন`)} aria-pressed={value===d.name} onClick={()=>choose(d.name)} onKeyDown={e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();moved.current=false;choose(d.name)}}} onPointerEnter={e=>{if(e.pointerType!=='touch')setHovered(d.name)}} onPointerLeave={()=>setHovered('')} onFocus={()=>setHovered(d.name)} onBlur={()=>setHovered('')}>
      <title>{nameOf(d.name)}{tr(' — select to find tutors',' — টিউটর খুঁজতে বেছে নিন')}</title><path className="district-face" d={d.path} fill={value===d.name?'#18594f':hovered===d.name?'#b9a47b':palette[d.color]} stroke={value===d.name?'#134f46':'#fbfaf6'} strokeWidth={value===d.name?'1.8':'.85'} fillRule="evenodd"/>
     </g>)}
     {labels&&<g className="map-labels" aria-hidden="true">{districts.map((d,i)=><g key={d.name} transform={`translate(0 ${value===d.name?-5:0})`} className={value===d.name?'selected-label':''}><text data-label-district={d.name} x={d.center[0]} y={d.center[1]} textAnchor="middle" dominantBaseline="central" clipPath={`url(#${mapId}-label-${i})`}>{nameOf(d.name)}</text></g>)}</g>}
    </g>
   </svg>
   <div className="map-zoom"><button aria-label="Zoom in map" onClick={()=>zoomTo(zoom+1)} disabled={zoom>=6||!districts.length}><Mark name="plus" size={16}/></button><span>{Math.round(zoom*100)}%</span><button aria-label="Zoom out map" onClick={()=>zoomTo(zoom-1)} disabled={zoom<=1}><Mark name="minus" size={16}/></button><button aria-label="Reset map view" onClick={reset} className="map-reset"><Mark name="reset" size={15}/></button></div>
   <span className="map-water-label" aria-hidden="true">{tr('BAY OF BENGAL','বঙ্গোপসাগর')}</span>
   {active&&<div className="map-hover-name" aria-hidden="true"><Mark name="pin" size={14}/>{nameOf(active)}</div>}
  </div>
  <div className="map-footer"><div className="map-selection"><span className={`map-selection-dot ${value?'chosen':''}`}/><span>{value?<><strong>{nameOf(value)}</strong><span className="map-selection-suffix">{tr(' selected',' নির্বাচিত')}</span></>:tr('Select a district to filter tutors','টিউটর খুঁজতে একটি জেলা বেছে নিন')}</span>{value&&<button onClick={()=>{onChange('');setHovered('')}} aria-label="Clear selected district"><Mark name="close" size={13}/></button>}</div><small>{zoom>1?tr('Drag to explore · Tap a district','টেনে দেখুন · জেলা বেছে নিন'):tr('Tap to select · Zoom for smaller districts','জেলা বেছে নিন · ছোট জেলা দেখতে জুম করুন')}</small></div>
  <div className="map-source">{tr('Boundary data','সীমানার তথ্য')}: <a href="https://www.geoboundaries.org/api/current/gbOpen/BGD/ADM2/" target="_blank" rel="noreferrer">geoBoundaries</a> · BBS / OCHA · CC BY 3.0 IGO</div>
 </div>
}
function MapDialog({district,onDistrictChange,onClose,lang,districtOptions}) {
 const ref=useRef(null),tr=(en,bn)=>lang==='bn'?bn:en
 useEffect(()=>{const previous=document.activeElement;ref.current.showModal();return()=>previous?.focus?.()},[])
 return <dialog ref={ref} className="map-dialog" onCancel={onClose} onClick={e=>{if(e.target===ref.current)onClose()}}><div className="map-dialog-header"><div><span>{tr('BANGLADESH TUTOR DIRECTORY','বাংলাদেশের টিউটর ডিরেক্টরি')}</span><h2>{tr('Choose where you’ll learn','কোথায় শিখতে চান?')}</h2></div><button className="map-icon-button" onClick={onClose} aria-label="Close map"><Mark name="close"/></button></div><DistrictMap value={district} onChange={onDistrictChange} expanded lang={lang}/><div className="map-dialog-footer"><label><span>{tr('Choose a district','জেলা বেছে নিন')}</span><select aria-label="District in expanded map" value={district} onChange={e=>onDistrictChange(e.target.value)}><option value="">{tr('All districts','সব জেলা')}</option>{districtOptions.map(d=><option key={d} value={d}>{localizedDistrict(d,lang)}</option>)}</select></label><button className="hero-search-button" onClick={onClose}>{tr('Apply district','জেলা নির্বাচন করুন')}<Mark name="arrow" size={17}/></button></div></dialog>
}
function DivisionMarquee({value,onChange,lang}) {
 const {data:geometry}=useGeometry()
 const tr=(en,bn)=>lang==='bn'?bn:en
 function tile(division,index,duplicate=false){
  const shapes=geometry.filter(d=>division.districts.includes(d.name))
  const points=shapes.flatMap(d=>[...d.path.matchAll(/(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/g)].map(m=>[+m[1],+m[2]]))
  let minX=Infinity,minY=Infinity,maxX=-Infinity,maxY=-Infinity
  for(const [x,y] of points){minX=Math.min(minX,x);minY=Math.min(minY,y);maxX=Math.max(maxX,x);maxY=Math.max(maxY,y)}
  const bounds=points.length?`${minX-6} ${minY-6} ${maxX-minX+12} ${maxY-minY+12}`:'0 0 640 650'
  return <button key={division.name} className={`division-tile ${value===division.name?'selected':''}`} tabIndex={duplicate?-1:0} aria-pressed={value===division.name} aria-label={tr(`Find tutors in ${division.name} division`,`${division.bn} বিভাগের টিউটর খুঁজুন`)} onClick={()=>onChange(value===division.name?'':division.name)}>
   <svg className="division-mini-map" viewBox={bounds} role="img" aria-label={tr(`${division.name} division map`,`${division.bn} বিভাগের মানচিত্র`)}>{shapes.map(d=><path key={d.name} d={d.path} fill={value===division.name?'#245b4b':palette[index]} stroke="#faf9f4" strokeWidth="1.2" fillRule="evenodd"/>)}</svg><strong>{tr(division.name,division.bn)}</strong><small>{tr(`${division.districts.length} districts`,`${new Intl.NumberFormat('bn').format(division.districts.length)} জেলা`)}</small>
  </button>
 }
 return <section className="division-explorer" aria-label="Browse tutors by division"><div className="division-explorer-heading"><span>{tr('FIND YOUR DIVISION','আপনার বিভাগ বেছে নিন')}</span></div><div className="division-marquee"><div className="division-track"><div className="division-group">{divisions.map((d,i)=>tile(d,i))}</div><div className="division-group marquee-copy" aria-hidden="true">{divisions.map((d,i)=>tile(d,i,true))}</div></div></div><p>{tr('Select a division, or choose a district on the map.','বিভাগ বেছে নিন, অথবা মানচিত্র থেকে জেলা নির্বাচন করুন।')}</p></section>
}
export default function Hero({district,division,districtOptions,onDistrictChange,onDivisionChange,onSearch,onOnline,lang}) {
 const [expanded,setExpanded]=useState(false),tr=(en,bn)=>lang==='bn'?bn:en
 return <section className="search-heading refined-hero" aria-label="Find tutors across Bangladesh" lang={lang==='bn'?'bn':'en'}><div className="container hero-layout"><div className="hero-copy"><div className="hero-eyebrow">{tr('HOME TUITION & ONLINE LEARNING','বাসায় এবং অনলাইনে পড়াশোনা')}</div><h1>{lang==='bn'?<>উপযুক্ত <span className="hero-tutor-word">টিউটর<Mark name="learn" size={34}/></span> খুঁজুন।</>:<>Find the right <span className="hero-tutor-word">tutor.<Mark name="learn" size={34}/></span></>}<br/><span>{tr('Close to home.','আপনার কাছেই।')}</span></h1><p className="hero-description">{tr('Thoughtful teaching starts with the right person. Find a tutor for your subject, your class and your neighbourhood — anywhere in Bangladesh.','সঠিক শিক্ষকের সঙ্গে শেখা হয় সহজ। আপনার বিষয়, শ্রেণি ও এলাকায় উপযুক্ত টিউটর খুঁজুন — বাংলাদেশের যেকোনো জায়গায়।')}</p><DivisionMarquee value={division} onChange={onDivisionChange} lang={lang}/><div className="hero-browse-actions"><button className="hero-search-button" onClick={onSearch}>{tr('Find tutors','টিউটর খুঁজুন')}<Mark name="arrow" size={18}/></button>{(division||district)&&<div className="hero-location-summary"><span>{district?localizedDistrict(district,lang):localizedDivision(division,lang)}</span><small>{district?tr('District selected','জেলা নির্বাচিত'):tr('Division selected','বিভাগ নির্বাচিত')}</small></div>}</div><button className="hero-online-link" onClick={onOnline}>{tr('Learning from anywhere?','যেকোনো জায়গা থেকে শিখতে চান?')}<span>{tr('Explore online tutors','অনলাইন টিউটর খুঁজুন')}<Mark name="arrow" size={15}/></span></button></div><div className="hero-map-column"><DistrictMap value={district} onChange={onDistrictChange} onExpand={()=>setExpanded(true)} lang={lang}/></div></div>{expanded&&<MapDialog district={district} onDistrictChange={onDistrictChange} onClose={()=>setExpanded(false)} lang={lang} districtOptions={districtOptions}/>}</section>
}
