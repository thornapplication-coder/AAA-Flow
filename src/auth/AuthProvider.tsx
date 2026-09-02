import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import i18n from '../lib/i18n'
import { supabase } from '../lib/supabase'
import type { UiLanguage, User } from '../lib/database.types'

interface AuthState {
  session: Session | null
  profile: User | null
  loading: boolean
  signIn: (email: string, password: string) => Promise<string | null>
  signOut: () => Promise<void>
  setLanguage: (language: UiLanguage) => Promise<void>
}

const AuthContext = createContext<AuthState | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<User | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    void supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      if (!data.session) setLoading(false)
    })
    const { data: sub } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next)
      if (!next) {
        setProfile(null)
        setLoading(false)
      }
    })
    return () => sub.subscription.unsubscribe()
  }, [])

  useEffect(() => {
    if (!session) return
    let cancelled = false
    setLoading(true)
    void supabase
      .from('users')
      .select('*')
      .eq('id', session.user.id)
      .maybeSingle()
      .then(({ data }) => {
        if (cancelled) return
        setProfile(data ?? null)
        if (data) void i18n.changeLanguage(data.language)
        setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [session])

  const value: AuthState = {
    session,
    profile,
    loading,
    signIn: async (email, password) => {
      const { error } = await supabase.auth.signInWithPassword({ email, password })
      return error ? error.message : null
    },
    signOut: async () => {
      await supabase.auth.signOut()
    },
    setLanguage: async (language) => {
      await i18n.changeLanguage(language)
      if (profile) {
        setProfile({ ...profile, language })
        await supabase.from('users').update({ language }).eq('id', profile.id)
      }
    },
  }

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth außerhalb von AuthProvider')
  return ctx
}
