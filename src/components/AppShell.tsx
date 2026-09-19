import { NavLink, Outlet } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../auth/AuthProvider'

export function AppShell() {
  const { t } = useTranslation()
  const { profile, signOut, setLanguage } = useAuth()
  const isTeam = profile?.role === 'team'

  return (
    <div className="shell">
      <header className="topbar">
        <div className="brand">
          <img src="/icon.svg" alt="" />
          {t('app.name')}
        </div>
        <nav className="nav">
          <NavLink to="/dashboard">{t('nav.dashboard')}</NavLink>
          <NavLink to="/projects">{t('nav.projects')}</NavLink>
          <NavLink to="/tasks">{t('nav.tasks')}</NavLink>
          <NavLink to="/risks">{t('nav.risks')}</NavLink>
          <NavLink to="/reports">{t('nav.reports')}</NavLink>
          {isTeam && <NavLink to="/admin">{t('nav.admin')}</NavLink>}
        </nav>
        <div className="user">
          <span className="name">
            {profile?.name}
            {profile?.role ? ` · ${t(`role.${profile.role}`)}` : ''}
          </span>
          <span className="version" title={t('app.version', { version: __APP_VERSION__ })}>
            {__APP_VERSION__}
          </span>
          <button
            type="button"
            aria-label={t('common.language')}
            onClick={() => void setLanguage(profile?.language === 'de' ? 'en' : 'de')}
          >
            {profile?.language === 'de' ? 'EN' : 'DE'}
          </button>
          <button type="button" onClick={() => void signOut()}>
            {t('auth.logout')}
          </button>
        </div>
      </header>
      <main className="content">
        <Outlet />
      </main>
    </div>
  )
}
