-- =============================================================================
-- Project Control Center — Migration 2/6: Hilfsfunktionen
-- Identität, Rollen, Sichtbarkeit, Referenznummern, Fortschritt, Gesamtlage
-- Alle Sichtbarkeitsfunktionen sind SECURITY DEFINER, damit RLS-Policies sie
-- ohne Rekursion und ohne Rechteschleife nutzen können. Die rechnenden
-- Funktionen sind es ebenfalls — sie prüfen deshalb selbst, ob der Fragende
-- das Projekt überhaupt sehen darf.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Identität und Rollen
-- Es gibt genau zwei Zugänge: 'team' darf alles, 'viewer' liest und gibt aus.
-- Beide werden gemeinsam benutzt. Die Rolle steckt in jeder Policy und lief
-- bisher je Zeile gegen public.users; der Wert ändert sich innerhalb einer
-- Anfrage nicht, also wird er transaktionslokal gemerkt.
-- -----------------------------------------------------------------------------
create or replace function pcc.my_role()
returns pcc.user_role
language plpgsql stable security definer set search_path = public, pcc as $$
declare
  v_key   text := coalesce(auth.uid()::text, '-');
  v_cache text := nullif(current_setting('app.pcc_role', true), '');
  v_role  text;
begin
  -- Der Merker trägt die Kennung mit: wechselt der angemeldete Zugang
  -- innerhalb derselben Transaktion, verfällt er von selbst.
  if v_cache is not null and split_part(v_cache, '|', 1) = v_key then
    return nullif(split_part(v_cache, '|', 2), '-')::pcc.user_role;
  end if;
  select role::text into v_role from public.users
   where auth_user_id = auth.uid() and active;
  perform set_config('app.pcc_role', v_key || '|' || coalesce(v_role, '-'), true);
  return v_role::pcc.user_role;
end $$;

-- Nach jeder Änderung an Rolle oder Zugang muss der Merker fallen.
create or replace function pcc.forget_role()
returns void
language sql volatile as $$
  select set_config('app.pcc_role', '', true);
$$;

-- Die Personenzeile des angemeldeten Zugangs. Sie steht im Audit-Trail als
-- beweiskräftige Herkunft — wer konkret am gemeinsamen Zugang gearbeitet hat,
-- sagt daneben actor_id (Angabe der Oberfläche).
create or replace function pcc.me()
returns uuid
language sql stable security definer set search_path = public, pcc as $$
  select id from public.users where auth_user_id = auth.uid();
$$;

create or replace function pcc.is_user()
returns boolean
language sql stable security definer set search_path = public, pcc as $$
  select pcc.my_role() is not null;
$$;
comment on function pcc.is_user() is 'Angemeldet an einem der beiden Zugänge. Ohne das greift keine einzige Policy.';

create or replace function pcc.is_team()
returns boolean
language sql stable security definer set search_path = public, pcc as $$
  select coalesce(pcc.my_role() = 'team', false);
$$;
comment on function pcc.is_team() is 'Der Zugang, der alles darf. Der zweite Zugang liest ausschließlich.';

-- Eine Person ist ansprechbar, wenn sie im Verzeichnis steht und aktiv ist.
-- Rechte hängen nicht daran: die haben nur die beiden Zugänge.
create or replace function pcc.is_person(p_user_id uuid)
returns boolean
language sql stable security definer set search_path = public, pcc as $$
  select exists (select 1 from public.users u where u.id = p_user_id and u.active);
$$;

-- -----------------------------------------------------------------------------
-- Wer arbeitet gerade?
-- Beide Zugänge werden gemeinsam benutzt. Damit Zuständigkeit und Trail nicht
-- bei „Teamzugang" enden, bekennt sich die Oberfläche beim Anmelden zu einer
-- Person aus dem Verzeichnis und schickt sie bei jedem Schreibvorgang mit.
-- Das ist eine Angabe, kein Nachweis — der Nachweis bleibt der Zugang. Ohne
-- brauchbare Angabe fällt alles auf die Personenzeile des Zugangs zurück.
-- -----------------------------------------------------------------------------
create or replace function pcc.set_actor(p_user_id uuid)
returns void
language plpgsql security definer set search_path = public, pcc as $$
begin
  if p_user_id is not null and not pcc.is_person(p_user_id) then
    raise exception 'PCC_STATE: Diese Person steht nicht im Verzeichnis' using errcode = 'P0001';
  end if;
  -- Transaktionslokal: der Wert darf nicht in die nächste Anfrage überlaufen,
  -- die über dieselbe Verbindung aus dem Bestand kommt.
  perform set_config('app.pcc_actor', coalesce(p_user_id::text, ''), true);
end $$;

create or replace function pcc.actor()
returns uuid
language sql stable security definer set search_path = public, pcc as $$
  select coalesce(nullif(current_setting('app.pcc_actor', true), '')::uuid, pcc.me());
$$;

-- Der von der Oberfläche benannte Mensch, sofern er im Verzeichnis steht;
-- sonst der angemeldete Zugang. Eine erfundene Kennung verfängt nicht.
create or replace function pcc.actor_or(p_claim uuid)
returns uuid
language sql stable security definer set search_path = public, pcc as $$
  select case when p_claim is not null and pcc.is_person(p_claim)
              then p_claim else pcc.actor() end;
$$;

-- -----------------------------------------------------------------------------
-- Sichtbarkeit und Schreibrecht
-- Mit zwei Zugängen ist die Frage einfach: lesen dürfen beide alles, ändern
-- darf nur der Teamzugang — und auch der nicht in einem archivierten Projekt.
-- Die Projektmitgliedschaft steuert seitdem keine Rechte mehr, sie sagt nur
-- noch, wer fachlich zum Projekt gehört.
-- -----------------------------------------------------------------------------
create or replace function pcc.can_read(p_project_id uuid)
returns boolean
language sql stable security definer set search_path = public, pcc as $$
  select pcc.is_user();
$$;
comment on function pcc.can_read(uuid) is 'Beide Zugänge lesen jedes Projekt, auch ein archiviertes.';

create or replace function pcc.can_edit(p_project_id uuid)
returns boolean
language sql stable security definer set search_path = public, pcc as $$
  select pcc.is_team()
     and exists (select 1 from pcc.projects p
                 where p.id = p_project_id and p.archived_at is null);
$$;
comment on function pcc.can_edit(uuid) is 'Ändern darf allein der Teamzugang. Archivierte Projekte sind auch für ihn schreibgeschützt.';

-- Gleichbedeutend mit can_edit — der Name bleibt, weil Policies und
-- Storage-Regeln ihn tragen und „beitragen" dort das Gemeinte besser trifft.
create or replace function pcc.can_contribute(p_project_id uuid)
returns boolean
language sql stable security definer set search_path = public, pcc as $$
  select pcc.can_edit(p_project_id);
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
