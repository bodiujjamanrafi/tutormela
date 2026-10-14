import { createClient } from '@supabase/supabase-js'
const url=import.meta.env.VITE_SUPABASE_URL
const key=import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY
export const configured=Boolean(url&&key&&key.startsWith('sb_publishable_')&&url.startsWith('https://'))
export const supabase=configured?createClient(url,key,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true,flowType:'pkce'}}):null
export function requireSupabase(){if(!supabase)throw new Error('Supabase configuration is missing. Check .env.local and restart the site.');return supabase}
