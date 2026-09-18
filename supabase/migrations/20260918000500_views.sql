-- =============================================================================
-- Project Control Center — Migration 5/5: Sichten
-- Alle Sichten mit security_invoker: sie zeigen genau das, was der anfragende
-- Nutzer auch direkt sehen dürfte. Eine Sicht ist kein Schlupfloch.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Projekte mit gerechneten Kennzahlen (Abschnitte 11, 12)
-- Fortschritt und Gesamtlage werden je Zeile über Funktionen gerechnet. Bei der
-- hier erwarteten Größenordnung — Dutzende Projekte, nicht Zehntausende — ist
-- das die verständlichere Lösung. Wird die Zahl größer, tritt an ihre Stelle
-- eine materialisierte Sicht, die der Tageslauf auffrischt.
-- -----------------------------------------------------------------------------
create view pcc.v_projects with (security_invoker = true) as
select
  p.id, p.key, p.name, p.description, p.objectives, p.scope, p.status,
  p.pm_user_id, pm.name as pm_name, p.sponsor_user_id,
  p.start_date, p.target_end_date, p.actual_end_date,
  p.archived_at is not null as archived,
  p.version_major || '.' || p.version_minor as version,
  pcc.project_progress(p.id) as progress,
  pcc.health(p.id) as health,
  (select count(*) from pcc.tasks t where t.project_id = p.id) as task_count,
  (select count(*) from pcc.tasks t
    where t.project_id = p.id and t.status not in ('completed', 'cancelled')
      and t.due_date < current_date) as overdue_tasks,
  (select count(*) from pcc.risks r
    where r.project_id = p.id and r.status in ('open', 'monitoring')) as open_risks,
  (select count(*) from pcc.risks r
    where r.project_id = p.id and r.status in ('open', 'monitoring') and r.score >= 15) as critical_risks,
  (select count(*) from pcc.issues i
    where i.project_id = p.id and i.status in ('open', 'in_progress', 'blocked')) as open_issues,
  (select count(*) from pcc.project_members m where m.project_id = p.id) as team_size,
  (select min(ms.due_date) from pcc.milestones ms
    where ms.project_id = p.id and ms.status <> 'completed') as next_milestone_date,
  (select ms.name from pcc.milestones ms
    where ms.project_id = p.id and ms.status <> 'completed'
    order by ms.due_date limit 1) as next_milestone,
  p.created_at, p.updated_at
from pcc.projects p
left join public.users pm on pm.id = p.pm_user_id;

-- -----------------------------------------------------------------------------
-- Aufgaben. „Überfällig" ist kein gespeicherter Status, sondern aus dem Termin
-- abgeleitet: sonst müsste ihn jemand pflegen, und niemand tut das zuverlässig.
-- -----------------------------------------------------------------------------
create view pcc.v_tasks with (security_invoker = true) as
select
  t.id, t.project_id, p.key as project_key, p.name as project_name,
  t.workstream_id, w.name as workstream, t.parent_task_id,
  t.ref, t.title, t.description, t.status, t.priority,
  t.assignee_user_id, u.name as assignee_name,
  t.start_date, t.due_date, t.completed_at,
  pcc.task_progress(t.id) as progress,
  t.status not in ('completed', 'cancelled') and t.due_date < current_date as overdue,
  case when t.status not in ('completed', 'cancelled') and t.due_date < current_date
       then current_date - t.due_date end as days_overdue,
  (select count(*) from pcc.tasks s where s.parent_task_id = t.id) as subtask_count,
  (select count(*) from pcc.tasks s where s.parent_task_id = t.id and s.status = 'completed') as subtasks_done,
  t.created_at, t.updated_at
from pcc.tasks t
join pcc.projects p on p.id = t.project_id
left join pcc.workstreams w on w.id = t.workstream_id
left join public.users u on u.id = t.assignee_user_id;

create view pcc.v_milestones with (security_invoker = true) as
select
  m.id, m.project_id, p.key as project_key, p.name as project_name,
  m.workstream_id, w.name as workstream, m.ref, m.name, m.description,
  m.due_date, m.baseline_date,
  case when m.baseline_date is not null then m.due_date - m.baseline_date end as slipped_days,
  m.status, m.owner_user_id, u.name as owner_name, m.depends_on_milestone_id,
  m.completed_at, m.notes,
  m.status <> 'completed' and m.due_date < current_date as overdue,
  m.due_date - current_date as days_to_due
from pcc.milestones m
join pcc.projects p on p.id = m.project_id
left join pcc.workstreams w on w.id = m.workstream_id
left join public.users u on u.id = m.owner_user_id;

create view pcc.v_risks with (security_invoker = true) as
select
  r.id, r.project_id, p.key as project_key, p.name as project_name,
  r.ref, r.title, r.description, r.category,
  r.probability, r.impact, r.score,
  r.score >= 15 as critical,
  r.owner_user_id, u.name as owner_name,
  r.mitigation, r.contingency, r.due_date, r.status, r.created_at
from pcc.risks r
join pcc.projects p on p.id = r.project_id
left join public.users u on u.id = r.owner_user_id;

create view pcc.v_issues with (security_invoker = true) as
select
  i.id, i.project_id, p.key as project_key, p.name as project_name,
  i.ref, i.title, i.description, i.priority, i.status,
  i.owner_user_id, u.name as owner_name, i.due_date, i.resolution, i.risk_id,
  i.status not in ('resolved', 'closed') and i.due_date < current_date as overdue,
  i.created_at
from pcc.issues i
join pcc.projects p on p.id = i.project_id
left join public.users u on u.id = i.owner_user_id;

-- -----------------------------------------------------------------------------
-- Dashboard (Abschnitt 11). Eine Zeile, über alle sichtbaren Projekte.
-- -----------------------------------------------------------------------------
create view pcc.v_dashboard with (security_invoker = true) as
select
  count(*)                                                       as projects_total,
  count(*) filter (where not archived
    and status not in ('completed', 'cancelled'))                as projects_active,
  count(*) filter (where status = 'on_track')                    as projects_on_track,
  count(*) filter (where status = 'at_risk')                     as projects_at_risk,
  count(*) filter (where status = 'delayed')                     as projects_delayed,
  count(*) filter (where status = 'completed')                   as projects_completed,
  count(*) filter (where health = 'red')                         as projects_red,
  count(*) filter (where health = 'amber')                       as projects_amber,
  coalesce(sum(open_risks), 0)                                   as open_risks,
  coalesce(sum(critical_risks), 0)                               as critical_risks,
  coalesce(sum(open_issues), 0)                                  as open_issues,
  coalesce(sum(overdue_tasks), 0)                                as overdue_tasks
from pcc.v_projects
where not archived;

create view pcc.v_overdue_tasks with (security_invoker = true) as
select * from pcc.v_tasks where overdue order by days_overdue desc;

create view pcc.v_upcoming_milestones with (security_invoker = true) as
select * from pcc.v_milestones
where status <> 'completed' and due_date between current_date and current_date + 30
order by due_date;

-- -----------------------------------------------------------------------------
-- Risk Matrix 5×5 (Abschnitt 17): jede Zelle mit Anzahl und Einträgen
-- -----------------------------------------------------------------------------
create view pcc.v_risk_matrix with (security_invoker = true) as
select
  r.project_id, r.probability, r.impact, r.probability * r.impact as score,
  count(*) as risk_count,
  array_agg(r.ref order by r.ref) as refs
from pcc.risks r
where r.status in ('open', 'monitoring')
group by r.project_id, r.probability, r.impact;

-- -----------------------------------------------------------------------------
-- Aktivität (Abschnitt 18). Speist sich aus dem gemeinsamen Audit-Trail.
-- -----------------------------------------------------------------------------
create view pcc.v_activity with (security_invoker = true) as
select
  a.id, a.created_at, a.project_id, p.key as project_key,
  a.user_id, u.name as user_name,
  a.entity, a.entity_id, a.action, a.reason,
  a.old_value, a.new_value
from public.audit_log a
left join public.users u on u.id = a.user_id
left join pcc.projects p on p.id = a.project_id;

create view pcc.v_my_notifications with (security_invoker = true) as
select n.*, p.key as project_key, p.name as project_name
from pcc.notifications n
left join pcc.projects p on p.id = n.project_id
where n.user_id = auth.uid();

-- -----------------------------------------------------------------------------
-- Offene Freigaben für den Super Admin (Abschnitt 4)
-- -----------------------------------------------------------------------------
create view pcc.v_pending_users with (security_invoker = true) as
select id, name, email, registered_at, pending, active
from public.users
where pending and not active;

grant select on all tables in schema pcc to authenticated;
revoke all on pcc.v_projects, pcc.v_tasks, pcc.v_milestones, pcc.v_risks,
  pcc.v_issues, pcc.v_dashboard, pcc.v_overdue_tasks, pcc.v_upcoming_milestones,
  pcc.v_risk_matrix, pcc.v_activity, pcc.v_my_notifications, pcc.v_pending_users from anon;

-- -----------------------------------------------------------------------------
-- Tageslauf einplanen. Auf Supabase steht pg_cron zur Verfügung, lokal in der
-- Regel nicht — dort wird run_daily_jobs() von Hand oder aus dem Test gerufen.
-- -----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('pcc_daily', '0 5 * * *', 'select pcc.run_daily_jobs()');
  else
    raise notice 'pg_cron nicht verfügbar: pcc.run_daily_jobs() muss extern (Edge Function oder Scheduler) aufgerufen werden';
  end if;
exception when others then
  raise notice 'pg_cron konnte nicht eingerichtet werden: %', sqlerrm;
end $$;
