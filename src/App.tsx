import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { AuthProvider, useAuth } from './auth/AuthProvider'
import { AppShell } from './components/AppShell'
import { LoginPage } from './pages/LoginPage'
import { ProjectsPage } from './pages/ProjectsPage'
import { Placeholder } from './pages/Placeholder'

function Protected() {
  const { t } = useTranslation()
  const { session, profile, loading, signOut } = useAuth()
  if (loading) return <div className="content muted">{t('common.loading')}</div>
  if (!session) return <Navigate to="/login" replace />
  // Ein Konto ohne Rolle ist ein Konto ohne Zugang: die Selbstregistrierung
  // erzeugt es gesperrt, erst der Super Admin gibt es frei (Abschnitt 4).
  if (!profile || !profile.role || !profile.active) {
    return (
      <div className="login">
        <div className="tile">
          <p>{t(profile ? 'auth.pending' : 'auth.noProfile')}</p>
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
            <Route index element={<Navigate to="/projects" replace />} />
            <Route path="/projects" element={<ProjectsPage />} />
            <Route path="/projects/:id" element={<Placeholder titleKey="nav.projects" />} />
            <Route path="/dashboard" element={<Placeholder titleKey="nav.dashboard" />} />
            <Route path="/tasks" element={<Placeholder titleKey="nav.tasks" />} />
            <Route path="/risks" element={<Placeholder titleKey="nav.risks" />} />
            <Route path="/reports" element={<Placeholder titleKey="nav.reports" />} />
            <Route path="/admin" element={<Placeholder titleKey="nav.admin" />} />
          </Route>
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  )
}
