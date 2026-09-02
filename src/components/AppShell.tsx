import { NavLink, Outlet } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../auth/AuthProvider'

export function AppShell() {
  const { t } = useTranslation()
  const { profile, signOut, setLanguage } = useAuth()
  const canSeeAll = profile?.role !== 'staff'

  return (
    <div className="shell">
      <header className="topbar">
        <div className="brand">
          <img src="/icon.svg" alt="" />
          {t('app.name')}
        </div>
        <nav className="nav">
          <NavLink to="/pool">{t('nav.pool')}</NavLink>
          <NavLink to="/my">{t('nav.my')}</NavLink>
          {canSeeAll && <NavLink to="/all">{t('nav.all')}</NavLink>}
          <NavLink to="/dashboard">{t('nav.dashboard')}</NavLink>
          {(profile?.role === 'superadmin' || profile?.role === 'admin') && <NavLink to="/admin">{t('nav.admin')}</NavLink>}
        </nav>
        <div className="user">
          <span className="name">
            {profile?.name} · {profile ? t(`department.${profile.department}`) : ''}
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
