import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { registerSW } from 'virtual:pwa-register'
import i18n from './lib/i18n'
import './styles/theme.css'
import { App } from './App'

// Eine neue Fassung wird angeboten, nicht aufgezwungen: mitten in einer
// Eingabe neu zu laden wäre Datenverlust (Architektur, Abschnitt 8).
const updateSW = registerSW({
  onNeedRefresh() {
    if (window.confirm(i18n.t('common.updateAvailable'))) void updateSW(true)
  },
})

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
