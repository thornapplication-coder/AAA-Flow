-- =============================================================================
-- Project Control Center — Migration 2/5: Hilfsfunktionen
-- Identität, Rollen, Sichtbarkeit, Referenznummern, Fortschritt, Gesamtlage
-- Alle Sichtbarkeitsfunktionen sind SECURITY DEFINER, damit RLS-Policies sie
-- ohne Rekursion und ohne Rechteschleife nutzen können. Die rechnenden
-- Funktionen sind es ebenfalls — sie prüfen deshalb selbst, ob der Fragende
-- das Projekt überhaupt sehen darf.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Identität und Rollen
-- -----------------------------------------------------------------------------
-- Diese Funktion steckt in jeder Policy und lief bisher je Zeile gegen
-- public.users. Der Wert ändert sich innerhalb einer Anfrage nicht, also wird
-- er transaktionslokal gemerkt. Ein leerer Eintrag bedeutet „kein Zugang" und
-- wird als Sonderwert abgelegt, damit auch er nur einmal kostet.
create or replace function pcc.my_role()
returns pcc.user_role
language plpgsql stable security definer set search_path = public, pcc as $$
declare
  v_key   text := coalesce(auth.uid()::text, '-');
  v_cache text := nullif(current_setting('app.pcc_role', true), '');
  v_role  text;
begin
  -- Der Merker trägt die Kennung mit: wechselt der angemeldete Nutzer
  -- innerhalb derselben Transaktion, verfällt er von selbst.
  if v_cache is not null and split_part(v_cache, '|', 1) = v_key then
    return nullif(split_part(v_cache, '|', 2), '-')::pcc.user_role;
  end if;
  select role::text into v_role from public.users
   where id = auth.uid() and active and not pending;
  perform set_config('app.pcc_role', v_key || '|' || coalesce(v_role, '-'), true);
  return v_role::pcc.user_role;
end $$;

-- Nach jeder Änderung an Rolle oder Freigabe muss der Merker fallen.
create or replace function pcc.forget_role()
returns void
language sql volatile as $$
  select set_config('app.pcc_role', '', true);
$$;

create or replace function pcc.is_user()
returns boolean
language sql stable security definer set search_path = public, pcc as $$
  select pcc.my_role() is not null;
$$;
comment on function pcc.is_user() is 'Zugang zum Control Center: aktives, freigegebenes Konto mit Rolle. Ohne das greift keine einzige Policy.';

create or replace function pcc.is_super_admin()
returns boolean
language sql stable security definer set search_path = public, pcc as $$
  select coalesce(pcc.my_role() = 'super_admin', false);
$$;

create or replace function pcc.is_admin()
returns boolean
language sql stable security definer set search_path = public, pcc as $$
  select coalesce(pcc.my_role() in ('super_admin', 'admin'), false);
$$;

-- -----------------------------------------------------------------------------
-- Sichtbarkeit und Schreibrecht
-- Abschnitt 4: Jeder freigegebene Nutzer liest alle nicht archivierten
-- Projekte. Geändert wird nur nach Rolle.
-- -----------------------------------------------------------------------------
create or replace function pcc.can_read(p_project_id uuid)
returns boolean
language sql stable security definer set search_path = public, pcc as $$
  select pcc.is_user() and (
    pcc.is_admin()
    or exists (select 1 from pcc.projects p where p.id = p_project_id and p.archived_at is null)
    or exists (select 1 from pcc.project_members m where m.project_id = p_project_id and m.user_id = auth.uid())
  );
$$;
comment on function pcc.can_read(uuid) is 'Archivierte Projekte sehen nur Mitglieder und die Admin-Ebene.';

-- Dieselbe Frage für eine andere Person: Darf sie dieses Projekt lesen? Wird
-- gebraucht, bevor eine Erwähnung den Anfang eines Kommentars mitschickt.
create or replace function pcc.can_read_as(p_project_id uuid, p_user_id uuid)
returns boolean
language sql stable security definer set search_path = public, pcc as $$
  select exists (select 1 from public.users u
                 where u.id = p_user_id and u.active and not u.pending and u.role is not null)
     and (exists (select 1 from public.users u
                  where u.id = p_user_id and u.role in ('super_admin', 'admin'))
          or exists (select 1 from pcc.projects p
                     where p.id = p_project_id and p.archived_at is null)
          or exists (select 1 from pcc.project_members m
                     where m.project_id = p_project_id and m.user_id = p_user_id));
$$;

create or replace function pcc.can_edit(p_project_id uuid)
returns boolean
language sql stable security definer set search_path = public, pcc as $$
  select pcc.is_user() and (
    pcc.is_admin()
    or exists (select 1 from pcc.projects p
               where p.id = p_project_id and p.pm_user_id = auth.uid() and p.archived_at is null)
  );
$$;
comment on function pcc.can_edit(uuid) is 'Vollzugriff auf ein Projekt: dessen Projektleitung, Admin oder Super Admin. Archivierte Projekte sind schreibgeschützt.';

-- Contributor: darf in Projekten mit Mitgliedschaft die ihm zugewiesenen
-- Einträge bearbeiten, Issues melden und kommentieren (Abschnitt 5).
create or replace function pcc.can_contribute(p_project_id uuid)
returns boolean
language sql stable security definer set search_path = public, pcc as $$
  select pcc.can_edit(p_project_id)
      or (coalesce(pcc.my_role() = 'contributor', false)
          and exists (select 1 from pcc.project_members m
                      where m.project_id = p_project_id and m.user_id = auth.uid())
          and exists (select 1 from pcc.projects p
                      where p.id = p_project_id and p.archived_at is null));
$$;

-- -----------------------------------------------------------------------------
-- Referenznummern je Projekt
-- -----------------------------------------------------------------------------
create or replace function pcc.next_ref(p_project_id uuid, p_prefix text)
returns text
language plpgsql security definer set search_path = public, pcc as $$
declare v integer;
begin
  insert into pcc.ref_counters (project_id, prefix, last_value)
  values (p_project_id, p_prefix, 1)
  on conflict (project_id, prefix)
    do update set last_value = pcc.ref_counters.last_value + 1
  returning last_value into v;
  return p_prefix || '-' || v::text;
end $$;

-- -----------------------------------------------------------------------------
-- Fortschritt
-- Abschnitt 21: „optional aus Teilaufgaben abgeleitet" heißt je Aufgabe
-- entscheidbar, nicht global. Deshalb progress_mode an der Zeile.
-- -----------------------------------------------------------------------------
create or replace function pcc.task_progress(p_task_id uuid)
returns smallint
language sql stable security definer set search_path = public, pcc as $$
  with t as (select * from pcc.tasks where id = p_task_id
             and pcc.can_read(project_id))
  select case
    when (select status from t) = 'completed' then 100::smallint
    when (select progress_mode from t) = 'manual' then (select progress from t)
    else coalesce((
      select round(avg(case when s.status = 'completed' then 100 else s.progress end))::smallint
      from pcc.tasks s
      where s.parent_task_id = p_task_id and s.status <> 'cancelled'
    ), (select progress from t))
  end;
$$;

create or replace function pcc.project_progress(p_project_id uuid)
returns smallint
language sql stable security definer set search_path = public, pcc as $$
  with p as (select * from pcc.projects where id = p_project_id
             and pcc.can_read(p_project_id))
  select case
    when (select progress_mode from p) = 'manual' then (select progress_manual from p)
    else coalesce((
      select round(avg(case when t.status = 'completed' then 100 else pcc.task_progress(t.id) end))::smallint
      from pcc.tasks t
      where t.project_id = p_project_id and t.parent_task_id is null and t.status <> 'cancelled'
    ), 0::smallint)
  end;
$$;

-- -----------------------------------------------------------------------------
-- Gesamtlage. Rot ist selten, sonst ist Rot nichts wert.
-- Rot: Status verzögert oder abgebrochen, überfälliger Meilenstein,
--      oder mindestens zwei kritische Risiken (Score >= 15).
-- Gelb: Status gefährdet, überfällige Aufgaben, ein kritisches Risiko,
--      oder Zieldatum überschritten.
-- -----------------------------------------------------------------------------
create or replace function pcc.health(p_project_id uuid)
returns pcc.health
language sql stable security definer set search_path = public, pcc as $$
  with cfg as (
    select coalesce((value ->> 'red_critical_risks')::integer, 2) as red_risks,
           coalesce((value ->> 'amber_critical_risks')::integer, 1) as amber_risks
    from pcc.settings where key = 'health'
  ),
  p as (select * from pcc.projects where id = p_project_id and pcc.can_read(p_project_id)),
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
comment on function pcc.health(uuid) is 'Gesamtlage wird gerechnet, nie gesetzt. Schwellen aus pcc.settings; rot bleibt selten, sonst verliert die Farbe ihre Aussage.';
