import { createClient } from '@supabase/supabase-js'
import type { Database } from './database.types'

const url = import.meta.env.VITE_SUPABASE_URL
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

if (!url || !anonKey) {
  throw new Error('VITE_SUPABASE_URL und VITE_SUPABASE_ANON_KEY fehlen — siehe .env.example')
}

export const supabase = createClient<Database>(url, anonKey, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
})

// Die Fachdaten liegen im Schema pcc, das Nutzerprofil in public. Beides über
// denselben Client, damit ein Token genügt.
export const pcc = supabase.schema('pcc')
