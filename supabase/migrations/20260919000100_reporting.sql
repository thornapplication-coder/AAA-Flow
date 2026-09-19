-- =============================================================================
-- Project Control Center — Migration 7: Berichtslinie zur Geschäftsführung
--
-- Der Prototyp hat vier Dinge bekommen, für die es hier noch keine Entsprechung
-- gab. Ohne sie ginge beim Umzug in die Datenbank genau das verloren, was einen
-- Bericht an die Leitung ausmacht:
--   1. Entscheidungsbedarf — die Frage, die beantwortet werden muss
--   2. Ampel-Trend — die Richtung, nicht nur der Zustand
--   3. Verschiebungshistorie der Meilensteine — Grundlage der Trendanalyse
--   4. Superadmin — wer die Verwaltung sieht
--
-- Gefunden bei der Freigabeprüfung zur Revision 1.0.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Entscheidungsbedarf
-- Eine Anfrage ohne Frist bleibt liegen — deshalb ist die Frist Pflicht.
-- Entschieden wird nicht hier, sondern in pcc.decisions: der Punkt trägt
-- danach die Kennung der Entscheidung, die aus ihm hervorgegangen ist.
-- -----------------------------------------------------------------------------
create type pcc.ask_status as enum ('open', 'decided', 'withdrawn');

create table pcc.decision_requests (
  id             uuid primary key default gen_random_uuid(),
  project_id     uuid not null references pcc.projects (id) on delete cascade,
  ref            text not null,
  topic          text not null check (length(trim(topic)) > 0),
  question       text not null check (length(trim(question)) > 0),
  options        text,
  recommendation text,
  due_date       date not null,
  decide_by      text,                       -- Gremium oder Rolle, frei benannt
  status         pcc.ask_status not null default 'open',
  decided_on     date,
  decision_id    uuid references pcc.decisions (id) on delete set null,
  created_at     timestamptz not null default now(),
  created_by     uuid references public.users (id),
  updated_at     timestamptz not null default now(),
  updated_by     uuid references public.users (id),
  unique (project_id, ref),
  -- Entschieden heißt: mit Datum. Sonst stünde ein Punkt als erledigt da,
  -- ohne dass jemand sagen könnte, wann das war.
  constraint decision_requests_decided_needs_date
    check (status <> 'decided' or decided_on is not null)
);
create index decision_requests_open_idx on pcc.decision_requests (project_id, due_date)
  where status = 'open';
comment on table pcc.decision_requests is
  'Was die Geschäftsführung entscheiden muss: Frage, Möglichkeiten, Empfehlung, Frist.';

create trigger decision_requests_ref before insert on pcc.decision_requests
  for each row execute function pcc.tg_set_ref('A');
create trigger decision_requests_ref_immutable before update on pcc.decision_requests
  for each row execute function pcc.tg_ref_immutable();
create trigger decision_requests_touch before update on pcc.decision_requests
  for each row execute function pcc.tg_touch();
create trigger decision_requests_created before insert on pcc.decision_requests
  for each row execute function pcc.tg_created_by();
create trigger decision_requests_audit after insert or update or delete on pcc.decision_requests
  for each row execute function pcc.tg_audit();
create trigger decision_requests_archived before insert or update or delete on pcc.decision_requests
  for each row execute function pcc.tg_archived_guard();

-- -----------------------------------------------------------------------------
-- 2. Ampel-Trend
-- Eine Zeile je Projekt und Kalenderwoche. Innerhalb der Woche wird
-- überschrieben: es zählt der Stand, mit dem die Woche endet.
-- -----------------------------------------------------------------------------
create table pcc.health_snapshots (
  project_id  uuid not null references pcc.projects (id) on delete cascade,
  iso_week    text not null check (iso_week ~ '^[0-9]{4}-[0-9]{2}$'),
  health      pcc.health not null,
  progress    smallint not null default 0 check (progress between 0 and 100),
  open_risks  smallint not null default 0,
  taken_at    timestamptz not null default now(),
  primary key (project_id, iso_week)
);
comment on table pcc.health_snapshots is
  'Die Lage je Projekt und Woche. Grundlage für „besser oder schlechter als beim letzten Bericht".';

-- Die Woche nach ISO 8601: Woche 1 ist die mit dem ersten Donnerstag.
-- to_char(..., 'IYYY-IW') liefert genau das — und beim Jahreswechsel das
-- richtige Bezugsjahr, was eine eigene Rechnung selten trifft.
create or replace function pcc.iso_week(p_day date default current_date)
returns text language sql immutable as $$
  select to_char(p_day, 'IYYY-IW');
$$;

-- pcc.health() gibt null zurück, wenn der Aufrufer das Projekt nicht lesen
-- darf. Für den Tageslauf ist das fatal: dort ist niemand angemeldet, also
-- wäre jede Momentaufnahme leer. Ohne Anmeldung läuft aber ausschließlich der
-- Systemlauf — anon darf die Funktion gar nicht ausführen. Deshalb greift die
-- Leseprüfung nur dann, wenn tatsächlich jemand angemeldet ist.
create or replace function pcc.health(p_project_id uuid)
returns pcc.health
language sql stable security definer set search_path = public, pcc as $$
  with cfg as (
    select coalesce((value ->> 'red_critical_risks')::integer, 2) as red_risks,
           coalesce((value ->> 'amber_critical_risks')::integer, 1) as amber_risks
    from pcc.settings where key = 'health'
  ),
  p as (select * from pcc.projects
         where id = p_project_id
           and (pcc.me() is null or pcc.can_read(p_project_id))),
  m as (
    select count(*) filter (
      where status <> 'completed' and due_date < current_date
    ) as overdue_ms
    from pcc.milestones where project_id = p_project_id
  ),
  t as (
    select count(*) filter (
      where status not in ('completed', 'cancelled') and due_date < current_date
    ) as overdue_tasks
    from pcc.tasks where project_id = p_project_id
  ),
  r as (
    select count(*) filter (
      where score >= coalesce((select (value ->> 'critical_score')::integer from pcc.settings where key = 'risk'), 15)
        and status in ('open', 'monitoring')
    ) as critical
    from pcc.risks where project_id = p_project_id
  )
  select case
    when not exists (select 1 from p) then null::pcc.health
    when (select status from p) = 'completed' then 'green'::pcc.health
    when (select status from p) in ('delayed', 'cancelled')
      or (select overdue_ms from m) > 0
      or (select critical from r) >= coalesce((select red_risks from cfg), 2) then 'red'::pcc.health
    when (select status from p) = 'at_risk'
      or (select overdue_tasks from t) > 0
      or (select critical from r) >= coalesce((select amber_risks from cfg), 1)
      or ((select target_end_date from p) is not null
          and (select target_end_date from p) < current_date) then 'amber'::pcc.health
    else 'green'::pcc.health
  end;
$$;

create or replace function pcc.take_health_snapshot(p_project_id uuid default null)
returns integer
language plpgsql security definer set search_path = public, pcc as $$
declare v_count integer;
begin
  insert into pcc.health_snapshots (project_id, iso_week, health, progress, open_risks)
  select p.id, pcc.iso_week(), pcc.health(p.id), pcc.project_progress(p.id),
         (select count(*) from pcc.risks r
           where r.project_id = p.id and r.status in ('open', 'monitoring'))
    from pcc.projects p
   where (p_project_id is null or p.id = p_project_id)
     and p.archived_at is null
  on conflict (project_id, iso_week) do update
    set health = excluded.health, progress = excluded.progress,
        open_risks = excluded.open_risks, taken_at = now();
  get diagnostics v_count = row_count;
  return v_count;
end $$;
comment on function pcc.take_health_snapshot is
  'Hält die Lage aller sichtbaren Projekte für die laufende Woche fest. Läuft im Tageslauf.';

-- Richtung seit der letzten erfassten früheren Woche: 1 besser, 0 gleich,
-- -1 schlechter. Verglichen wird nie mit dem Eintrag derselben Woche.
create or replace function pcc.health_trend(p_project_id uuid)
returns table (direction integer, from_health pcc.health, to_health pcc.health, from_week text)
language sql stable as $$
  with letzte as (
    select * from pcc.health_snapshots
     where project_id = p_project_id order by iso_week desc limit 1
  ), vorher as (
    select s.* from pcc.health_snapshots s, letzte l
     where s.project_id = p_project_id and s.iso_week < l.iso_week
     order by s.iso_week desc limit 1
  ), rang as (
    select 'green'::pcc.health as h, 0 as r
    union all select 'amber', 1 union all select 'red', 2
  )
  select case when rv.r > rl.r then 1 when rv.r < rl.r then -1 else 0 end,
         v.health, l.health, v.iso_week
    from letzte l join vorher v on true
    join rang rl on rl.h = l.health
    join rang rv on rv.h = v.health;
$$;

-- -----------------------------------------------------------------------------
-- 3. Verschiebungshistorie der Meilensteine
-- baseline_date gibt es bereits; was fehlte, ist die Spur dazwischen. Ohne sie
-- lässt sich zwar der Verzug beziffern, aber nicht zeigen, seit wann er
-- entsteht — und genau das ist die Trendanalyse.
-- -----------------------------------------------------------------------------
create table pcc.milestone_shifts (
  id           uuid primary key default gen_random_uuid(),
  milestone_id uuid not null references pcc.milestones (id) on delete cascade,
  shifted_on   date not null default current_date,
  from_date    date,
  to_date      date not null,
  reason       text,
  created_by   uuid references public.users (id)
);
create index milestone_shifts_idx on pcc.milestone_shifts (milestone_id, shifted_on);
comment on table pcc.milestone_shifts is
  'Jede Terminverschiebung eines Meilensteins mit Datum. Zeigt, seit wann ein Termin wandert.';

create or replace function pcc.tg_milestone_shift()
returns trigger
language plpgsql security definer set search_path = public, pcc as $$
begin
  if tg_op = 'INSERT' then
    insert into pcc.milestone_shifts (milestone_id, from_date, to_date, created_by)
      values (new.id, null, new.due_date, pcc.actor_or(new.created_by));
  elsif new.due_date is distinct from old.due_date then
    insert into pcc.milestone_shifts (milestone_id, from_date, to_date, created_by)
      values (new.id, old.due_date, new.due_date, pcc.actor_or(new.updated_by));
  end if;
  return new;
end $$;
create trigger milestones_shift after insert or update of due_date on pcc.milestones
  for each row execute function pcc.tg_milestone_shift();

-- -----------------------------------------------------------------------------
-- 4. Superadmin
-- Eine Verabredung mit Zähnen: Hier entscheidet die Datenbank, nicht die
-- Oberfläche. Der letzte Superadmin bleibt — sonst kommt niemand mehr in die
-- Verwaltung.
-- -----------------------------------------------------------------------------
alter table public.users add column is_super boolean not null default false;
comment on column public.users.is_super is
  'Sieht die Verwaltung und vergibt Rechte. Mindestens eine aktive Person trägt es.';

create or replace function pcc.is_super()
returns boolean language sql stable security definer set search_path = public, pcc as $$
  select coalesce((select u.is_super and u.active
                     from public.users u where u.id = pcc.me()), false);
$$;

create or replace function public.tg_users_last_super()
returns trigger
language plpgsql as $$
begin
  -- Greift auch beim Stilllegen: eine inaktive Person zählt nicht mehr.
  if (old.is_super and not new.is_super) or (old.is_super and old.active and not new.active) then
    if not exists (select 1 from public.users u
                    where u.id <> old.id and u.is_super and u.active) then
      raise exception 'PCC_STATE: Der letzte Superadmin bleibt bestehen' using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;
create trigger users_last_super before update on public.users
  for each row execute function public.tg_users_last_super();

-- -----------------------------------------------------------------------------
-- Sichten für den Bericht
-- -----------------------------------------------------------------------------
create or replace view pcc.v_decision_requests as
  select r.id, r.project_id, p.key as project_key, p.name as project_name,
         r.ref, r.topic, r.question, r.options, r.recommendation,
         r.due_date, r.decide_by, r.status, r.decided_on, r.decision_id,
         (r.status = 'open' and r.due_date < current_date) as overdue,
         u.name as raised_by, r.created_at
    from pcc.decision_requests r
    join pcc.projects p on p.id = r.project_id
    left join public.users u on u.id = r.created_by;

-- Termintreue je Projekt: wie viele Meilensteine wanderten, und wie weit.
create or replace view pcc.v_schedule_drift as
  select m.project_id,
         count(*) filter (where m.baseline_date is not null
                            and m.due_date > m.baseline_date)            as moved,
         count(*)                                                        as total,
         coalesce(max(m.due_date - m.baseline_date), 0)                  as max_slip_days,
         coalesce(sum(greatest(0, s.shifts - 1)), 0)                     as shifts
    from pcc.milestones m
    left join lateral (select count(*) as shifts from pcc.milestone_shifts x
                        where x.milestone_id = m.id) s on true
   group by m.project_id;

-- -----------------------------------------------------------------------------
-- Rechte
-- -----------------------------------------------------------------------------
grant select on pcc.decision_requests, pcc.health_snapshots, pcc.milestone_shifts,
      pcc.v_decision_requests, pcc.v_schedule_drift to authenticated;
grant insert, update, delete on pcc.decision_requests to authenticated;
revoke all on pcc.decision_requests, pcc.health_snapshots, pcc.milestone_shifts from anon;

alter table pcc.decision_requests enable row level security;
alter table pcc.decision_requests force row level security;
alter table pcc.health_snapshots enable row level security;
alter table pcc.health_snapshots force row level security;
alter table pcc.milestone_shifts enable row level security;
alter table pcc.milestone_shifts force row level security;

create policy decision_requests_select on pcc.decision_requests for select to authenticated
  using (pcc.can_read(project_id));
create policy decision_requests_write on pcc.decision_requests for all to authenticated
  using (pcc.can_edit(project_id)) with check (pcc.can_edit(project_id));

-- Momentaufnahmen und Verschiebungen schreibt die Anwendung nicht: sie
-- entstehen im Tageslauf und im Trigger. Gelesen werden sie von beiden Zugängen.
create policy health_snapshots_select on pcc.health_snapshots for select to authenticated
  using (pcc.can_read(project_id));
create policy milestone_shifts_select on pcc.milestone_shifts for select to authenticated
  using (exists (select 1 from pcc.milestones m
                  where m.id = milestone_id and pcc.can_read(m.project_id)));

revoke execute on function pcc.take_health_snapshot(uuid) from authenticated, anon, public;
grant execute on function pcc.take_health_snapshot(uuid) to service_role;
grant execute on function pcc.iso_week(date), pcc.health_trend(uuid), pcc.is_super() to authenticated;
