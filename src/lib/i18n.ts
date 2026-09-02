import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'
import de from '../locales/de.json'
import en from '../locales/en.json'

// Sprache je Nutzer umschaltbar (Spec Abschnitt 3); betrifft nur die
// Oberfläche, nie eingegebene Inhalte. Der Startwert kommt aus dem
// Nutzerprofil (users.language) und wird im AuthProvider gesetzt.
void i18n.use(initReactI18next).init({
  resources: { de: { translation: de }, en: { translation: en } },
  lng: 'de',
  fallbackLng: 'de',
  interpolation: { escapeValue: false },
})

export default i18n
