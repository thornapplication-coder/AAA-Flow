import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { pcc } from '../lib/supabase'
import type { ProjectOverview } from '../lib/database.types'

// Projektübersicht (Abschnitt 11). Fortschritt, Gesamtlage und Kennzahlen
// kommen fertig gerechnet aus pcc.v_projects — der Client rechnet nichts nach,
// sonst stünden zwei Wahrheiten nebeneinander.
export function ProjectsPage() {
  const { t } = useTranslation()
  const [rows, setRows] = useState<ProjectOverview[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const load = useCallback(async () => {
    setLoading(true)
    const { data, error: err } = await pcc
      .from('v_projects')
      .select('*')
      .eq('archived', false)
      .order('key')
    setError(err?.message ?? null)
    setRows(data ?? [])
    setLoading(false)
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  if (loading) return <div className="muted">{t('common.loading')}</div>

  return (
    <>
      <h1>{t('projects.title')}</h1>
      <p className="muted">{t('projects.intro')}</p>
      {error && <p className="error">{t('common.error')}: {error}</p>}
      {!error && rows.length === 0 && <p className="muted">{t('common.noEntries')}</p>}
      {rows.length > 0 && (
        <table>
          <thead>
            <tr>
              <th>{t('projects.key')}</th>
              <th>{t('projects.name')}</th>
              <th>{t('projects.pm')}</th>
              <th>{t('projects.progress')}</th>
              <th>{t('projects.nextMilestone')}</th>
              <th>{t('projects.openRisks')}</th>
              <th>{t('projects.overdueTasks')}</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((p) => (
              <tr key={p.id}>
                <td className="num">{p.key}</td>
                <td>
                  {p.name}
                  <span className={`chip health-${p.health}`}>{t(`health.${p.health}`)}</span>
                </td>
                <td>{p.pm_name ?? '—'}</td>
                <td>{p.progress}&nbsp;%</td>
                <td>{p.next_milestone ?? '—'}</td>
                <td>{p.open_risks}</td>
                <td>{p.overdue_tasks}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  )
}
