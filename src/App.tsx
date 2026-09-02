import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { AuthProvider, useAuth } from './auth/AuthProvider'
import { AppShell } from './components/AppShell'
import { LoginPage } from './pages/LoginPage'
import { PoolPage } from './pages/PoolPage'
import { Placeholder } from './pages/Placeholder'

function Protected() {
  const { t } = useTranslation()
  const { session, profile, loading, signOut } = useAuth()
  if (loading) return <div className="content muted">{t('common.loading')}</div>
  if (!session) return <Navigate to="/login" replace />
  if (!profile) {
    return (
      <div className="login">
        <div className="tile">
          <p>{t('auth.noProfile')}</p>
          <button type="button" onClick={() => void signOut()}>{t('auth.logout')}</button>
        </div>
      </div>
    )
  }
  return <AppShell />
}

export function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route element={<Protected />}>
            <Route index element={<Navigate to="/pool" replace />} />
            <Route path="/pool" element={<PoolPage />} />
            <Route path="/my" element={<Placeholder titleKey="nav.my" />} />
            <Route path="/all" element={<Placeholder titleKey="nav.all" />} />
            <Route path="/cases/:id" element={<Placeholder titleKey="case.number" />} />
            <Route path="/dashboard" element={<Placeholder titleKey="nav.dashboard" />} />
            <Route path="/admin" element={<Placeholder titleKey="nav.admin" />} />
          </Route>
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  )
}
