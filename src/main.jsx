import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.jsx'
import './Navigation.css'

// Map zoom is handled locally by DistrictMap; page gestures keep the layout fixed.
const preventPageZoom=event=>{if(event.type==='wheel'?(event.ctrlKey||event.metaKey):true)event.preventDefault()}
document.addEventListener('wheel',preventPageZoom,{passive:false})
document.addEventListener('gesturestart',preventPageZoom,{passive:false})
document.addEventListener('gesturechange',preventPageZoom,{passive:false})

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
