import { useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../auth/AuthProvider'

export function LoginPage() {
  const { t } = useTranslation()
  const { signIn } = useAuth()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    const message = await signIn(email, password)
    if (message) setError(t('auth.failed'))
    setBusy(false)
  }

  return (
    <div className="login">
      <div className="tile">
        <div className="brand" style={{ color: 'var(--aaa-navy-900)', marginBottom: 16 }}>
          <img src="/icon.svg" alt="" />
          {t('app.name')}
        </div>
        <p className="muted">{t('app.tagline')}</p>
        <form onSubmit={(e) => void onSubmit(e)}>
          <input type="email" autoComplete="username" placeholder={t('auth.email')} value={email} onChange={(e) => setEmail(e.target.value)} required />
          <input type="password" autoComplete="current-password" placeholder={t('auth.password')} value={password} onChange={(e) => setPassword(e.target.value)} required />
          {error && <div className="error">{error}</div>}
          <button className="primary" type="submit" disabled={busy}>
            {t('auth.login')}
          </button>
        </form>
        <p className="muted" style={{ fontSize: 13, marginBottom: 0 }}>{t('auth.noSelfSignup')}</p>
      </div>
    </div>
  )
}
