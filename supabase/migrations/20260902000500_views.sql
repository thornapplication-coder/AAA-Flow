-- =============================================================================
-- AAA Flow — Migration 5/5: Views für Listen, Pool und Dashboard; Cron
-- Alle Views laufen mit security_invoker, RLS der Basistabellen greift.
-- Statusmodell (Spec 13): open | in_progress | done | overdue — overdue dominiert.
-- =============================================================================

create or replace view public.v_case_checkpoints
with (security_invoker = true) as
select
  cc.id,
  cc.case_id,
  cc.checkpoint_id,
  cp.code,
  cp.gate_no,
  cp.department,
  cp.label_de,
  cp.label_en,
  cp.mandatory,
  cp.four_eyes,
  cp.evidence,
  cp.requires_gate_complete,
  cp.sort_order,
  cc.status,
  cc.due_at,
  cc.completed_by,
  cc.completed_at,
  cc.verified_by,
  cc.verified_at,
  cc.note,
  exists (select 1 from public.exceptions e
           where e.case_id = cc.case_id and e.checkpoint_id = cc.checkpoint_id and e.status = 'approved') as has_exception,
  exists (select 1 from public.exceptions e
           where e.case_id = cc.case_id and e.checkpoint_id = cc.checkpoint_id and e.status = 'requested') as exception_requested,
  (cc.status <> 'verified' and cc.due_at is not null and cc.due_at < current_date
     and not exists (select 1 from public.exceptions e
                      where e.case_id = cc.case_id and e.checkpoint_id = cc.checkpoint_id and e.status = 'approved')) as is_overdue,
  case
    when cc.status <> 'verified' and cc.due_at is not null and cc.due_at < current_date
         and not exists (select 1 from public.exceptions e
                          where e.case_id = cc.case_id and e.checkpoint_id = cc.checkpoint_id and e.status = 'approved')
      then 'overdue'
    when cc.status = 'verified' then 'done'
    when cc.status = 'completed' then 'in_progress'
    else 'open'
  end as display_state
from public.case_checkpoints cc
join public.checkpoints cp on cp.id = cc.checkpoint_id;

create or replace view public.v_gates
with (security_invoker = true) as
select
  g.case_id,
  g.gate_no,
  g.status,
  g.released_by,
  g.released_at,
  public.gate_release_department(g.gate_no) as release_department,
  count(v.id) filter (where v.mandatory and v.display_state <> 'done' and not v.has_exception) as open_mandatory,
  count(v.id) filter (where v.mandatory) as total_mandatory,
  bool_or(v.is_overdue) as is_overdue,
  case
    when g.status = 'released' then 'done'
    when bool_or(v.is_overdue) then 'overdue'
    when g.status = 'in_progress' then 'in_progress'
    else 'open'
  end as display_state
from public.gates g
left join public.v_case_checkpoints v on v.case_id = g.case_id and v.gate_no = g.gate_no
group by g.case_id, g.gate_no, g.status, g.released_by, g.released_at;

create or replace view public.v_cases
with (security_invoker = true) as
select
  c.id,
  c.case_number,
  c.status,
  c.trainee_id,
  t.name as trainee_name,
  t.date_of_birth as trainee_dob,
  c.company_id,
  co.name as company_name,
  c.aircraft_type_id,
  at.name as aircraft_type,
  c.course_type,
  c.enquiry_date,
  c.course_start,
  c.course_end,
  c.instructor,
  c.examiner,
  c.fstd_slot,
  c.closed_reason,
  c.created_by,
  c.created_at,
  c.updated_at,
  sa.user_id as sales_user_id,
  us.name as sales_user_name,
  ta.user_id as training_admin_user_id,
  ut.name as training_admin_user_name,
  ao.user_id as ato_user_id,
  ua.name as ato_user_name,
  g1.display_state as gate1_state,
  g2.display_state as gate2_state,
  g3.display_state as gate3_state,
  case
    when c.status = 'enquiry' then 1
    when c.status = 'booked' then 2
    when c.status in ('released', 'in_progress') then 3
    else null
  end as current_gate,
  nt.id as next_checkpoint_id,
  nt.label_de as next_task_de,
  nt.label_en as next_task_en,
  nt.department as next_task_department,
  nt.due_at as next_task_due_at,
  coalesce(g1.is_overdue, false) or coalesce(g2.is_overdue, false) or coalesce(g3.is_overdue, false) as is_overdue,
  exists (select 1 from public.exceptions e where e.case_id = c.id and e.status = 'approved') as has_exception,
  exists (select 1 from public.exceptions e where e.case_id = c.id and e.status = 'requested') as has_open_exception_request,
  (sa.user_id is null or ta.user_id is null or ao.user_id is null) as has_pool_entry,
  case
    when c.status in ('completed') then 'done'
    when c.status = 'discarded' then 'discarded'
    when coalesce(g1.is_overdue, false) or coalesce(g2.is_overdue, false) or coalesce(g3.is_overdue, false) then 'overdue'
    when exists (select 1 from public.case_checkpoints cc where cc.case_id = c.id and cc.status <> 'open') then 'in_progress'
    else 'open'
  end as display_state
from public.cases c
join public.trainees t on t.id = c.trainee_id
join public.companies co on co.id = c.company_id
join public.aircraft_types at on at.id = c.aircraft_type_id
left join public.case_assignments sa on sa.case_id = c.id and sa.department = 'sales'
left join public.users us on us.id = sa.user_id
left join public.case_assignments ta on ta.case_id = c.id and ta.department = 'training_admin'
left join public.users ut on ut.id = ta.user_id
left join public.case_assignments ao on ao.case_id = c.id and ao.department = 'ato'
left join public.users ua on ua.id = ao.user_id
left join public.v_gates g1 on g1.case_id = c.id and g1.gate_no = 1
left join public.v_gates g2 on g2.case_id = c.id and g2.gate_no = 2
left join public.v_gates g3 on g3.case_id = c.id and g3.gate_no = 3
left join lateral (
  select v.id, v.label_de, v.label_en, v.department, v.due_at
  from public.v_case_checkpoints v
  where v.case_id = c.id and v.display_state in ('open', 'in_progress', 'overdue') and v.mandatory and not v.has_exception
    and v.gate_no = coalesce(case
      when c.status = 'enquiry' then 1
      when c.status = 'booked' then 2
      when c.status in ('released', 'in_progress') then 3 end, 0)
  order by v.due_at nulls last, v.sort_order
  limit 1
) nt on true;

-- Pool: unzugewiesene Vorgänge je Abteilung, reduzierte Darstellung (Spec 9)
create or replace view public.v_pool
with (security_invoker = true) as
select
  ca.department,
  ca.pool_since,
  public.business_days_between(ca.pool_since::date, current_date) as business_days_in_pool,
  ca.stale_notified_at is not null as is_stale,
  v.id as case_id,
  v.case_number,
  v.status,
  v.trainee_name,
  v.company_name,
  v.aircraft_type,
  v.aircraft_type_id,
  v.course_type,
  v.course_start,
  v.next_task_de,
  v.next_task_en,
  v.next_task_department,
  v.next_task_due_at,
  v.display_state
from public.case_assignments ca
join public.v_cases v on v.id = ca.case_id
where ca.user_id is null
  and v.status not in ('completed', 'discarded');

-- Vorgangsbahn (Spec 13): Bestand je Stufe und Blockierer je Gate
create or replace view public.v_pipeline
with (security_invoker = true) as
select
  count(*) filter (where status = 'enquiry') as enquiry,
  count(*) filter (where status = 'enquiry' and gate1_state in ('in_progress', 'overdue')) as gate1_blocking,
  count(*) filter (where status = 'booked') as booked,
  count(*) filter (where status = 'booked' and gate2_state in ('in_progress', 'overdue')) as gate2_blocking,
  count(*) filter (where status in ('released', 'in_progress')) as in_progress,
  count(*) filter (where status in ('released', 'in_progress') and gate3_state in ('in_progress', 'overdue')) as gate3_blocking,
  count(*) filter (where status = 'completed') as completed,
  count(*) filter (where status not in ('completed', 'discarded')) as open_cases,
  count(*) filter (where is_overdue and status not in ('completed', 'discarded')) as overdue_cases,
  count(*) filter (where has_pool_entry and status not in ('completed', 'discarded')) as pool_cases,
  count(*) filter (where status = 'completed' and updated_at >= now() - interval '30 days') as completed_30d,
  (select count(*) from public.exceptions e where e.status = 'approved' and e.decided_at >= now() - interval '30 days') as exceptions_30d,
  count(*) filter (where status = 'completed' and gate3_state <> 'done') as gate3_warnings
from public.v_cases;

-- Ausnahmen nach Abteilung, Muster und Prüfpunkt (Spec 12, Punkt 4)
create or replace view public.v_exception_stats
with (security_invoker = true) as
select
  cp.department,
  at.name as aircraft_type,
  cp.code as checkpoint_code,
  cp.label_de,
  cp.label_en,
  count(*) filter (where e.status = 'approved') as approved,
  count(*) filter (where e.status = 'rejected') as rejected,
  count(*) filter (where e.status = 'requested') as pending,
  max(e.requested_at) as last_requested_at
from public.exceptions e
join public.checkpoints cp on cp.id = e.checkpoint_id
join public.cases c on c.id = e.case_id
join public.aircraft_types at on at.id = c.aircraft_type_id
group by cp.department, at.name, cp.code, cp.label_de, cp.label_en;

-- Gate-Durchlaufzeiten in Tagen (Anlage → Gate 1, Gate 1 → Gate 2, Gate 2 → Gate 3)
create or replace view public.v_gate_lead_times
with (security_invoker = true) as
select
  c.id as case_id,
  c.case_number,
  at.name as aircraft_type,
  extract(day from g1.released_at - c.created_at)::integer as days_to_gate1,
  extract(day from g2.released_at - g1.released_at)::integer as days_gate1_to_gate2,
  extract(day from g3.released_at - g2.released_at)::integer as days_gate2_to_gate3
from public.cases c
join public.aircraft_types at on at.id = c.aircraft_type_id
left join public.gates g1 on g1.case_id = c.id and g1.gate_no = 1 and g1.status = 'released'
left join public.gates g2 on g2.case_id = c.id and g2.gate_no = 2 and g2.status = 'released'
left join public.gates g3 on g3.case_id = c.id and g3.gate_no = 3 and g3.status = 'released';

-- Ungelesen-Zähler je Thread für den aktuellen Nutzer
create or replace view public.v_unread_threads
with (security_invoker = true) as
select
  m.scope,
  m.scope_id,
  count(*) as unread
from public.messages m
left join public.thread_reads r on r.user_id = auth.uid() and r.scope = m.scope and r.scope_id = m.scope_id
where m.user_id <> auth.uid()
  and m.created_at > coalesce(r.last_read_at, '-infinity'::timestamptz)
group by m.scope, m.scope_id;

grant select on public.v_case_checkpoints, public.v_gates, public.v_cases, public.v_pool, public.v_pipeline,
                public.v_exception_stats, public.v_gate_lead_times, public.v_unread_threads
  to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Tagesjob per pg_cron (auf Supabase im Dashboard aktivierbar). Fällt still
-- zurück, wenn die Extension nicht verfügbar ist; dann übernimmt eine Edge
-- Function mit Scheduler den Aufruf von run_daily_jobs().
-- -----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.unschedule(jobid) from cron.job where jobname = 'aaa_flow_daily';
    perform cron.schedule('aaa_flow_daily', '15 5 * * *', $job$ select public.run_daily_jobs(); $job$);
  else
    raise notice 'pg_cron nicht verfügbar: run_daily_jobs() muss extern (Edge Function / Scheduler) aufgerufen werden';
  end if;
exception when others then
  raise notice 'pg_cron konnte nicht eingerichtet werden: %', sqlerrm;
end $$;
