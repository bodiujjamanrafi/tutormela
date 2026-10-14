import {useState} from 'react'

// Original vector artwork: every visible element is an SVG shape, with no image assets.
export default function AuthIllustration(){
 const [paused,setPaused]=useState(false)
 return <div className={`auth-reference-art ${paused?'is-paused':''}`}>
  <svg viewBox="0 0 480 360" className="auth-reference-scene" aria-hidden="true" focusable="false" fill="none" strokeLinecap="round" strokeLinejoin="round">
   {/* A small shelf of course books places the scene in a real study space. */}
   <path d="M58 93h122" stroke="#c3cec3" strokeWidth="3"/>
   <path d="M69 94v7m99-7v7" stroke="#aab9ad" strokeWidth="2"/>
   <rect x="75" y="45" width="15" height="46" rx="2" fill="#a8bcae"/>
   <path d="M79 53h7M79 81h7" stroke="#edf2e9" strokeWidth="2"/>
   <rect x="92" y="36" width="19" height="55" rx="2" fill="#547c6b"/>
   <path d="M98 43v41M102 50h4M102 55h4" stroke="#bdcfc0" strokeWidth="1.5"/>
   <rect x="113" y="50" width="13" height="41" rx="2" fill="#c4ad85"/>
   <path d="M117 57h5M117 83h5" stroke="#eee5d3" strokeWidth="1.5"/>
   <path d="m131 43 16-4 12 49-16 4Z" fill="#d5dad0"/>
   <path d="m136 50 9-2m-4 36 9-2" stroke="#8f9e90" strokeWidth="1.6"/>
   {/* Chair and lower body stay still while the upper body breathes gently. */}
   <path d="M146 183c0-10 7-17 17-17h35c10 0 16 7 16 17v83h-68Z" fill="#e1e8de" stroke="#98aa99" strokeWidth="2"/>
   <path d="M152 257h69v12h-69Z" fill="#829a87"/>
   <path d="m163 268-9 62m49-62 9 62" stroke="#6c8272" strokeWidth="4"/>
   <path d="M184 232h45c14 0 23 7 25 20l6 43-25 4-11-43h-34Z" fill="#34483f"/>
   <path d="M185 245c-7 3-9 11-6 22l15 48 22-6-10-50 29-5" fill="#486052"/>
   <path d="m195 310 5 14 16-4-2-14" fill="#bd8769"/>
   <path d="m239 294 3 15 16-2-1-15" fill="#bd8769"/>
   <path d="M197 320c-5 7-9 9-15 11-4 1-5 5-3 8h41v-15l-7-5Z" fill="#293c34"/>
   <path d="M241 307c-1 8-5 13-10 17-3 3-3 7 0 9h39l-9-24-9 2Z" fill="#293c34"/>
   <path d="M181 336h37m17-6h31" stroke="#7f9484" strokeWidth="2"/>
   <g className="auth-person-motion">
    {/* Tailored shirt, natural proportions and a quiet, focused expression. */}
    <path d="M192 157c-15 5-26 15-32 34l-9 28 23 9 13-24-3 35h58l-1-34 16 19 17-14-18-33c-8-12-18-18-34-20Z" fill="#386d5c"/>
    <path d="m199 153 1 18 13 8 12-10-4-18" fill="#bd886c"/>
    <path d="m197 160 16 17-10 11-13-26m34-2-11 17 8 9 11-23" fill="#f1f2e8"/>
    <path d="M214 184v47" stroke="#285242" strokeWidth="2"/>
    <path d="M178 195l-8 21m64-24 6 17" stroke="#254f40" strokeWidth="2"/>
    <path d="M176 225c9 2 15 3 24 3l22 4-3 10-29-2-29-8Z" fill="#c39174"/>
    <path d="m242 221 17-8 15 12-9 12-15-9-19 10-6-10Z" fill="#c39174"/>
    <path d="m261 226 10 4m-55 6 7 3" stroke="#a87158" strokeWidth="1.5"/>
    <path d="m266 225 15 18" stroke="#30493b" strokeWidth="2.5"/>
    <path d="m280 240 3 5" stroke="#b69c71" strokeWidth="2"/>
    <path d="M185 113c0-22 14-35 31-33 20 2 30 17 27 35l-4 25c-2 13-12 24-24 23-13-1-25-16-26-30Z" fill="#c99477"/>
    <path d="M188 118c-12-9-15-27-5-39 7-9 17-14 27-11 5-4 15-3 21 2 12 2 19 12 17 23-1 8-6 13-12 17l-3-16c-10 5-20 5-28 1-1 11-4 17-11 21l-2 12-7-4Z" fill="#2c3e34"/>
    <path d="M191 88c7-10 18-12 28-9" stroke="#506455" strokeWidth="2"/>
    <path d="M192 119c-7-5-12-1-10 6 1 6 5 10 11 8" fill="#bf876b"/>
    <path d="m188 122 3 4" stroke="#986448" strokeWidth="1.6"/>
    <path d="m206 117 6-1m15 1 6 2" stroke="#504537" strokeWidth="2"/>
    <path d="M210 123v1m19 1v1" stroke="#2b3e32" strokeWidth="2.4"/>
    <path d="m222 126 3 8-5 1" stroke="#a56f52" strokeWidth="1.6"/>
    <path d="M213 145c4 2 8 2 12-1" stroke="#825941" strokeWidth="1.8"/>
    <path d="M231 145c-2 7-7 11-14 12" stroke="#b78061" strokeWidth="1.5"/>
   </g>
   {/* Solid wood desk and a laptop; no floating UI, fake numbers or labels. */}
   <path d="M130 249h288v10H130Z" fill="#c2a780"/>
   <path d="M132 248h284" stroke="#88775a" strokeWidth="2"/>
   <path d="m145 259-9 77m265-77 10 77" stroke="#647c6b" strokeWidth="5"/>
   <path d="M156 259v16m235-16v16" stroke="#9aa994" strokeWidth="2"/>
   <path d="M292 179h103c4 0 7 3 6 7l-11 55H279l9-58c0-2 2-4 4-4Z" fill="#385448"/>
   <path d="M295 184h99l-10 51H286Z" fill="#dfebe0"/>
   <path d="M297 192h88l-7 36h-87Z" fill="#eef3e9"/>
   <path d="m307 203 5 5 9-10" stroke="#76977e" strokeWidth="2"/>
   <path d="M331 201h40m-40 8h28m-53 10h61" stroke="#bfcebc" strokeWidth="2"/>
   <path d="M271 241h129l7 6H268Z" fill="#9fb2a0"/>
   <path d="M316 242h32" stroke="#728b76" strokeWidth="1.7"/>
   <path d="M174 237c13-7 28-7 44-2 13-5 26-5 39 0l4 11c-17-5-30-4-43 1-14-5-29-6-46-2Z" fill="#fffdf4" stroke="#c5bfa8" strokeWidth="1.5"/>
   <path d="m218 235 1 11m-35-7 20 1m-22 2 20 1m29-4 18-1m-16 4 17-1" stroke="#c0c8b4" strokeWidth="1.2"/>
   <rect x="76" y="312" width="43" height="10" rx="1.5" fill="#668775"/>
   <path d="M79 315h34v4H79Z" fill="#f5f2e5"/>
   <rect x="70" y="322" width="53" height="11" rx="1.5" fill="#c0ab87"/>
   <path d="M74 325h42v5H74Z" fill="#fbf7eb"/>
   <path d="M57 340h377" stroke="#c9d3c5" strokeWidth="1.5"/>
  </svg>
  <button type="button" className="auth-art-motion-control" aria-label={paused?'Play illustration animation':'Pause illustration animation'} aria-pressed={paused} onClick={()=>setPaused(v=>!v)}>{paused?<svg viewBox="0 0 16 16" aria-hidden="true"><path d="m5 3 8 5-8 5Z" fill="currentColor"/></svg>:<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M5 3v10M11 3v10" fill="none" stroke="currentColor" strokeWidth="1.6"/></svg>}</button>
 </div>
}
