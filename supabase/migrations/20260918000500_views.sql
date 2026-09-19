-- =============================================================================
-- Project Control Center — Migration 5/6: Sichten
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
  count(*) filter (where status not in ('completed', 'cancelled')) as projects_active,
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

-- -----------------------------------------------------------------------------
-- Abhängigkeiten als Kanten, mit Widerspruchsprüfung (19.09.2026)
-- Eine Verbindung ist dann etwas wert, wenn sie auffällt, sobald der Plan ihr
-- widerspricht: „erst wenn das fertig ist" und der Nachfolger beginnt vorher.
-- -----------------------------------------------------------------------------
create view pcc.v_task_links with (security_invoker = true) as
select
  d.id, d.project_id, d.kind, d.lag_days, d.note,
  d.predecessor_id, pre.ref as predecessor_ref, pre.title as predecessor_title,
  pre.start_date as predecessor_start, pre.due_date as predecessor_due, pre.status as predecessor_status,
  d.successor_id, suc.ref as successor_ref, suc.title as successor_title,
  suc.start_date as successor_start, suc.due_date as successor_due, suc.status as successor_status,
  -- Der früheste Tag, an dem der Nachfolger nach dieser Verbindung beginnen darf.
  case when d.kind = 'finish_start' then pre.due_date + d.lag_days
       else pre.start_date + d.lag_days end as earliest_start,
  -- Widerspruch: der Nachfolger ist früher angesetzt, als die Verbindung erlaubt.
  case when suc.start_date is null then false
       when d.kind = 'finish_start' then suc.start_date < pre.due_date + d.lag_days
       else suc.start_date < pre.start_date + d.lag_days end as conflict,
  case when suc.start_date is null then 0
       when d.kind = 'finish_start' then greatest(0, (pre.due_date + d.lag_days) - suc.start_date)
       else greatest(0, (pre.start_date + d.lag_days) - suc.start_date) end as conflict_days
from pcc.task_dependencies d
join pcc.tasks pre on pre.id = d.predecessor_id
join pcc.tasks suc on suc.id = d.successor_id;
comment on view pcc.v_task_links is 'Abhängigkeiten zwischen Aufgaben samt frühestem zulässigem Beginn und Hinweis, wo der Plan ihnen widerspricht.';

-- -----------------------------------------------------------------------------
-- Gantt je Projekt (Auftrag vom 19.09.2026)
-- Eine Zeile je Balken: Teilprojekte als Klammer über ihre Aufgaben, darunter
-- die Aufgaben mit ihren Terminen, dazu die Meilensteine als Punkt. Ein
-- Teilprojekt trägt keine eigenen Termine — sie ergeben sich aus dem, was
-- darin zu tun ist; deshalb rechnet die Sicht sie hier und nicht die
-- Oberfläche, die sonst je Anwendung anders rechnete.
-- -----------------------------------------------------------------------------
create view pcc.v_gantt with (security_invoker = true) as
-- 1. Teilprojekte
select
  w.project_id,
  'workstream'::text                       as kind,
  w.id                                     as id,
  null::uuid                               as parent_id,
  w.id                                     as workstream_id,
  w.name                                   as label,
  null::text                               as ref,
  w.owner_user_id                          as person_id,
  min(t.start_date)                        as start_date,
  max(t.due_date)                          as due_date,
  null::pcc.task_status                    as task_status,
  null::pcc.milestone_status               as milestone_status,
  -- Der Fortschritt eines Teilprojekts ist der Mittelwert seiner obersten
  -- Aufgaben; Teilaufgaben zählen über ihr Elternteil mit.
  coalesce(round(avg(case when t.status in ('completed', 'cancelled') then 100
                          else t.progress end) filter (where t.parent_task_id is null)), 0)::smallint as progress,
  count(*) filter (where t.status not in ('completed', 'cancelled'))::integer as open_count,
  w.sort_order                             as sort_order,
  0                                        as depth
from pcc.workstreams w
left join pcc.tasks t on t.workstream_id = w.id
group by w.project_id, w.id, w.name, w.owner_user_id, w.sort_order

union all
-- 2. Aufgaben und Teilaufgaben
select
  t.project_id, 'task', t.id, t.parent_task_id, t.workstream_id, t.title, t.ref,
  t.assignee_user_id, t.start_date, t.due_date, t.status, null,
  case when t.status in ('completed', 'cancelled') then 100 else t.progress end::smallint,
  case when t.status in ('completed', 'cancelled') then 0 else 1 end,
  t.sort_order,
  case when t.parent_task_id is null then 1 else 2 end
from pcc.tasks t

union all
-- 3. Meilensteine: ein Punkt, kein Balken
select
  m.project_id, 'milestone', m.id, null, m.workstream_id, m.name, m.ref,
  m.owner_user_id, null, m.due_date, null, m.status,
  case when m.status = 'completed' then 100 else 0 end::smallint,
  case when m.status = 'completed' then 0 else 1 end,
  32767, 1
from pcc.milestones m;
comment on view pcc.v_gantt is 'Zeilen für die Gantt-Darstellung eines Projekts: Teilprojekte mit abgeleiteten Terminen, Aufgaben, Teilaufgaben und Meilensteine.';

-- -----------------------------------------------------------------------------
-- Versionsverlauf eines Projekts (Abschnitt 22)
-- Sortiert wird nach Haupt- und Nebennummer, nicht nach Text: sonst käme 1.10
-- vor 1.9 zu liegen. Die Anzahl der erfassten Änderungen hängt gleich mit dran.
-- -----------------------------------------------------------------------------
create view pcc.v_versions with (security_invoker = true) as
select
  v.id, v.project_id, p.key as project_key, v.version,
  split_part(v.version, '.', 1)::integer as version_major,
  split_part(v.version, '.', 2)::integer as version_minor,
  v.trigger_code, t.label_de as trigger_label_de, t.label_en as trigger_label_en, v.summary,
  v.created_at, v.created_by, u.name as created_by_name,
  (select count(*) from pcc.version_changes c where c.version_id = v.id) as change_count
from pcc.project_versions v
join pcc.projects p on p.id = v.project_id
left join pcc.version_triggers t on t.code = v.trigger_code
left join public.users u on u.id = v.created_by
order by v.project_id, version_major desc, version_minor desc;

-- Benachrichtigungen gehören Personen, nicht Zugängen. Die Sicht zeigt alle
-- mit Namen; wen es angeht, entscheidet die Oberfläche anhand der Person, als
-- die man sich angemeldet hat.
create view pcc.v_notifications with (security_invoker = true) as
select n.*, u.name as user_name, p.key as project_key, p.name as project_name
from pcc.notifications n
left join public.users u on u.id = n.user_id
left join pcc.projects p on p.id = n.project_id;

-- -----------------------------------------------------------------------------
-- Personenverzeichnis (Abschnitt 4)
-- -----------------------------------------------------------------------------
-- Wer steht zur Verfügung, und welche der beiden Zeilen trägt einen Zugang?
create view pcc.v_people with (security_invoker = true) as
select id, name, email, job_title, active, role,
       (auth_user_id is not null) as has_account,
       (select count(*) from pcc.tasks t
         where t.assignee_user_id = u.id and t.status not in ('completed', 'cancelled')) as open_tasks
from public.users u
order by name;

grant select on all tables in schema pcc to authenticated;
revoke all on pcc.v_projects, pcc.v_tasks, pcc.v_milestones, pcc.v_risks,
  pcc.v_issues, pcc.v_dashboard, pcc.v_overdue_tasks, pcc.v_upcoming_milestones,
  pcc.v_risk_matrix, pcc.v_activity, pcc.v_versions, pcc.v_gantt, pcc.v_task_links,
  pcc.v_notifications, pcc.v_people from anon;

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
