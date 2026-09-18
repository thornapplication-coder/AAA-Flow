import { useTranslation } from 'react-i18next'

// Platzhalter für Bereiche, die im nächsten Ausbauschritt folgen
// (Dashboard, Projektakte, Aufgaben, Risiken, Berichte, Administration).
export function Placeholder({ titleKey }: { titleKey: string }) {
  const { t } = useTranslation()
  return (
    <>
      <h1>{t(titleKey)}</h1>
      <div className="tile">
        <p className="muted">{t('common.comingSoon')}</p>
      </div>
    </>
  )
}
