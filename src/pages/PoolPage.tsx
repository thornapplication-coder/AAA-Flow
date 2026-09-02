import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../auth/AuthProvider'
import { supabase } from '../lib/supabase'
import type { PoolEntry } from '../lib/database.types'

// Pool (Spec 9): unzugewiesene Vorgänge der eigenen Abteilung, reduzierte
// Darstellung, ein Klick übernimmt. Sales sieht per RLS nur die eigenen Muster.
export function PoolPage() {
  const { t, i18n } = useTranslation()
  const { profile } = useAuth()
  const [rows, setRows] = useState<PoolEntry[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const load = useCallback(async () => {
    if (!profile) return
    setLoading(true)
    const { data, error: err } = await supabase
      .from('v_pool')
      .select('*')
      .eq('department', profile.department)
      .order('pool_since', { ascending: true })
    setError(err?.message ?? null)
    setRows(data ?? [])
    setLoading(false)
  }, [profile])

  useEffect(() => {
    void load()
  }, [load])

  async function claim(caseId: string) {
    const { error: err } = await supabase.rpc('claim_case', { p_case_id: caseId })
    if (err) setError(err.message)
    await load()
  }

  const task = (r: PoolEntry) => (i18n.language === 'en' ? r.next_task_en : r.next_task_de) ?? '—'

  return (
    <>
      <h1>{t('pool.title')}</h1>
      <div className="tile">
        <p className="muted">{t('pool.intro', { department: profile ? t(`department.${profile.department}`) : '' })}</p>
        {error && <div className="error">{error}</div>}
        {loading && <p className="muted">{t('common.loading')}</p>}
        {!loading && rows.length === 0 && <p className="muted">{t('common.noEntries')}</p>}
        {rows.length > 0 && (
          <>
            <div className="table-wrap">
              <table className="list">
                <thead>
                  <tr>
                    <th>{t('case.number')}</th>
                    <th>{t('case.company')}</th>
                    <th>{t('case.trainee')}</th>
                    <th>{t('case.aircraftType')}</th>
                    <th>{t('case.courseStart')}</th>
                    <th>{t('case.nextTask')}</th>
                    <th>{t('case.inPoolSince')}</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => (
                    <tr key={r.case_id}>
                      <td>
                        {r.case_number} <span className={`state ${r.display_state}`}>{t(`state.${r.display_state}`)}</span>
                      </td>
                      <td>{r.company_name}</td>
                      <td>{r.trainee_name}</td>
                      <td>{r.aircraft_type}</td>
                      <td>{r.course_start ?? '—'}</td>
                      <td>{task(r)}</td>
                      <td>
                        {r.business_days_in_pool} {t('case.businessDays')}
                        {r.is_stale && <span className="state overdue" style={{ marginLeft: 8 }}>{t('case.stale')}</span>}
                      </td>
                      <td>
                        <button className="primary" type="button" onClick={() => void claim(r.case_id)}>
                          {t('common.claim')}
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="cards">
              {rows.map((r) => (
                <div className="tile" key={r.case_id}>
                  <strong>{r.case_number}</strong> <span className={`state ${r.display_state}`}>{t(`state.${r.display_state}`)}</span>
                  <div>{r.company_name} · {r.trainee_name}</div>
                  <div className="muted">{r.aircraft_type} · {r.course_start ?? '—'}</div>
                  <div className="muted">{task(r)}</div>
                  <button className="primary" type="button" style={{ marginTop: 8 }} onClick={() => void claim(r.case_id)}>
                    {t('common.claim')}
                  </button>
                </div>
              ))}
            </div>
          </>
        )}
      </div>
    </>
  )
}
