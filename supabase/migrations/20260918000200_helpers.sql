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
-- Terminrechnung: Puffer und kritischer Pfad (Auftrag vom 19.09.2026)
-- Rückwärts vom Projektende: Wie lange darf eine Aufgabe spätestens dauern,
-- ohne ihre Nachfolger und damit das Projektende zu verschieben? Was keinen
-- Puffer mehr hat, liegt auf dem kritischen Pfad.
--
-- Die Rekursion sammelt je Weg einen Kandidaten und nimmt außen den frühesten
-- — das ist die übliche Rückwärtsrechnung, nur in SQL geschrieben. Die Tiefe
-- ist begrenzt: ein Kreis kann zwar nicht entstehen (Trigger in Migration 3),
-- aber ein Schutz kostet nichts.
-- -----------------------------------------------------------------------------
create or replace function pcc.critical_path(p_project_id uuid)
returns table (task_id uuid, late_finish date, slack_days integer, is_critical boolean)
language sql stable security definer set search_path = public, pcc as $$
  -- recursive gilt für die ganze Liste, auch wenn nur rec sich selbst ruft.
  with recursive t as (
    select x.id,
           x.start_date,
           x.due_date,
           -- Dauer in Kalendertagen; ohne Beginn zählt die Aufgabe als Punkt.
           coalesce(x.due_date - x.start_date, 0) as span
      from pcc.tasks x
     where x.project_id = p_project_id
       and x.due_date is not null
       and pcc.can_read(p_project_id)
  ),
  horizon as (
    select coalesce(
             (select p.target_end_date from pcc.projects p where p.id = p_project_id),
             (select max(due_date) from t)) as h
  ),
  rec as (
    -- Aufgaben ohne Nachfolger dürfen bis zum Projektende laufen.
    select t.id, (select h from horizon) as late_finish, 0 as depth
      from t
     where not exists (select 1 from pcc.task_dependencies d
                        where d.predecessor_id = t.id
                          and exists (select 1 from t s where s.id = d.successor_id))
    union all
    select d.predecessor_id,
           case when d.kind = 'finish_start'
                -- Der Vorgänger muss fertig sein, bevor der Nachfolger beginnt.
                then (r.late_finish - succ.span) - d.lag_days
                -- Bei „zugleich beginnen" darf er so lange laufen wie er dauert.
                else (r.late_finish - succ.span) - d.lag_days + pred.span
           end,
           r.depth + 1
      from rec r
      join pcc.task_dependencies d on d.successor_id = r.id
      join t succ on succ.id = d.successor_id
      join t pred on pred.id = d.predecessor_id
     where r.depth < 100
  )
  select t.id,
         min(rec.late_finish)::date,
         (min(rec.late_finish) - t.due_date)::integer,
         (min(rec.late_finish) - t.due_date) <= 0
    from t
    join rec on rec.id = t.id
   group by t.id, t.due_date;
$$;
comment on function pcc.critical_path(uuid) is 'Puffer je Aufgabe in Tagen und der kritische Pfad: was keinen Puffer hat, verschiebt bei Verzug das Projektende.';

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

-- -----------------------------------------------------------------------------
-- Was hat sich seit einem Stichtag geändert? (Auftrag vom 19.09.2026)
-- Der Wochenbericht ist die Frage, die jede Leitungsrunde stellt. Sie lässt
-- sich aus dem Trail beantworten — dort steht alles, mit Zeitpunkt und Person.
-- Ohne Projekt gilt sie für alle sichtbaren Projekte.
-- -----------------------------------------------------------------------------
create or replace function pcc.changes_since(
  p_since      timestamptz,
  p_project_id uuid default null
)
returns table (
  at         timestamptz,
  project_id uuid,
  project_key text,
  entity     text,
  action     text,
  label      text,
  detail     text,
  person     text
)
language sql stable security definer set search_path = public, pcc as $$
  select
    a.created_at,
    a.project_id,
    p.key,
    a.entity,
    a.action,
    -- Der sprechende Name des Gegenstands, soweit die Zeile ihn mitführt.
    coalesce(a.new_value ->> 'title', a.new_value ->> 'name',
             a.old_value ->> 'title', a.old_value ->> 'name', a.entity_id),
    -- Was genau: bei einem Statuswechsel der Weg von A nach B.
    case
      when a.new_value ->> 'status' is distinct from (a.old_value ->> 'status')
           and a.old_value is not null
        then coalesce(a.old_value ->> 'status', '—') || ' → ' || coalesce(a.new_value ->> 'status', '—')
      when a.new_value ->> 'due_date' is distinct from (a.old_value ->> 'due_date')
           and a.old_value is not null
        then coalesce(a.old_value ->> 'due_date', '—') || ' → ' || coalesce(a.new_value ->> 'due_date', '—')
      else a.reason
    end,
    u.name
  from public.audit_log a
  left join pcc.projects p on p.id = a.project_id
  left join public.users u on u.id = coalesce(a.actor_id, a.user_id)
 where a.created_at >= p_since
   and (p_project_id is null or a.project_id = p_project_id)
   and (a.project_id is null or pcc.can_read(a.project_id))
   and pcc.is_user()
 order by a.created_at desc;
$$;
comment on function pcc.changes_since(timestamptz, uuid) is 'Grundlage des Wochenberichts: was sich seit einem Stichtag geändert hat, mit Zeitpunkt, Gegenstand und Person.';

-- -----------------------------------------------------------------------------
-- Globale Suche (Auftrag vom 19.09.2026)
-- Über alles hinweg, was einen Namen trägt. pg_trgm steht seit Migration 1 zur
-- Verfügung; die Ähnlichkeit fängt Tippfehler ab, die ein blankes LIKE
-- durchgehen ließe.
-- -----------------------------------------------------------------------------
create or replace function pcc.search(p_query text, p_limit integer default 40)
returns table (
  kind       text,
  id         uuid,
  project_id uuid,
  project_key text,
  ref        text,
  label      text,
  context    text,
  rank       real
)
language sql stable security definer set search_path = public, pcc as $$
  with q as (select trim(p_query) as s)
  select * from (
    select 'project', p.id, p.id, p.key, p.key, p.name,
           coalesce(p.description, ''), similarity(p.name || ' ' || p.key, (select s from q))
      from pcc.projects p where pcc.can_read(p.id)
        and (p.name ilike '%' || (select s from q) || '%' or p.key ilike '%' || (select s from q) || '%')
    union all
    select 'workstream', w.id, w.project_id, p.key, null, w.name,
           coalesce(w.description, ''), similarity(w.name, (select s from q))
      from pcc.workstreams w join pcc.projects p on p.id = w.project_id
     where pcc.can_read(w.project_id)
       and w.name ilike '%' || (select s from q) || '%'
    union all
    select 'task', t.id, t.project_id, p.key, t.ref, t.title,
           coalesce(t.description, ''), similarity(t.title, (select s from q))
      from pcc.tasks t join pcc.projects p on p.id = t.project_id
     where pcc.can_read(t.project_id)
       and (t.title ilike '%' || (select s from q) || '%' or t.ref ilike (select s from q))
    union all
    select 'milestone', m.id, m.project_id, p.key, m.ref, m.name,
           coalesce(m.description, ''), similarity(m.name, (select s from q))
      from pcc.milestones m join pcc.projects p on p.id = m.project_id
     where pcc.can_read(m.project_id)
       and (m.name ilike '%' || (select s from q) || '%' or m.ref ilike (select s from q))
    union all
    select 'risk', r.id, r.project_id, p.key, r.ref, r.title,
           coalesce(r.mitigation, r.description, ''), similarity(r.title, (select s from q))
      from pcc.risks r join pcc.projects p on p.id = r.project_id
     where pcc.can_read(r.project_id)
       and (r.title ilike '%' || (select s from q) || '%' or r.ref ilike (select s from q))
    union all
    select 'issue', i.id, i.project_id, p.key, i.ref, i.title,
           coalesce(i.description, ''), similarity(i.title, (select s from q))
      from pcc.issues i join pcc.projects p on p.id = i.project_id
     where pcc.can_read(i.project_id)
       and (i.title ilike '%' || (select s from q) || '%' or i.ref ilike (select s from q))
    union all
    select 'decision', d.id, d.project_id, p.key, d.ref, d.topic,
           coalesce(d.decision, ''), similarity(d.topic || ' ' || coalesce(d.decision, ''), (select s from q))
      from pcc.decisions d join pcc.projects p on p.id = d.project_id
     where pcc.can_read(d.project_id)
       and (d.topic ilike '%' || (select s from q) || '%'
            or d.decision ilike '%' || (select s from q) || '%' or d.ref ilike (select s from q))
    union all
    select 'document', dc.id, dc.project_id, p.key, null, dc.title,
           coalesce(dc.description, ''), similarity(dc.title, (select s from q))
      from pcc.documents dc join pcc.projects p on p.id = dc.project_id
     where pcc.can_read(dc.project_id) and dc.deleted_at is null
       and dc.title ilike '%' || (select s from q) || '%'
  ) hits (kind, id, project_id, project_key, ref, label, context, rank)
  where length((select s from q)) >= 2 and pcc.is_user()
  order by rank desc nulls last, label
  limit greatest(1, least(p_limit, 200));
$$;
comment on function pcc.search(text, integer) is 'Suche über Projekte, Teilprojekte, Aufgaben, Meilensteine, Risiken, Probleme, Entscheidungen und Dokumente. Was der Fragende nicht lesen darf, kommt nicht zurück.';

-- -----------------------------------------------------------------------------
-- Termine als iCalendar (Auftrag vom 19.09.2026)
-- Meilensteine und Aufgabenfristen dort, wo die Leute ohnehin hinsehen: im
-- eigenen Kalender. Ganztägige Einträge; DTEND ist bei iCalendar der Tag
-- danach, sonst fehlt der letzte Tag im Eintrag.
-- -----------------------------------------------------------------------------
create or replace function pcc.calendar(p_project_id uuid default null)
returns text
language sql stable security definer set search_path = public, pcc as $$
  with items as (
    select m.id, m.due_date as day, p.key as pkey,
           m.ref || ' ' || m.name as summary,
           'Meilenstein · ' || coalesce(u.name, 'ohne Verantwortliche') ||
             ' · Status: ' || m.status::text as note
      from pcc.milestones m
      join pcc.projects p on p.id = m.project_id
      left join public.users u on u.id = m.owner_user_id
     where (p_project_id is null or m.project_id = p_project_id)
       and pcc.can_read(m.project_id) and m.status <> 'completed'
    union all
    select t.id, t.due_date, p.key,
           t.ref || ' ' || t.title,
           'Aufgabe fällig · ' || coalesce(u.name, 'ohne Zuständige') ||
             ' · Status: ' || t.status::text
      from pcc.tasks t
      join pcc.projects p on p.id = t.project_id
      left join public.users u on u.id = t.assignee_user_id
     where (p_project_id is null or t.project_id = p_project_id)
       and pcc.can_read(t.project_id)
       and t.due_date is not null
       and t.status not in ('completed', 'cancelled')
  )
  select case when not pcc.is_user() then null else
    'BEGIN:VCALENDAR' || chr(13) || chr(10) ||
    'VERSION:2.0' || chr(13) || chr(10) ||
    'PRODID:-//Aviation Academy Austria//Project Control Center//DE' || chr(13) || chr(10) ||
    'CALSCALE:GREGORIAN' || chr(13) || chr(10) ||
    'METHOD:PUBLISH' || chr(13) || chr(10) ||
    'X-WR-CALNAME:Project Control Center' || chr(13) || chr(10) ||
    coalesce(string_agg(
      'BEGIN:VEVENT' || chr(13) || chr(10) ||
      'UID:' || i.id || '@control-center' || chr(13) || chr(10) ||
      'DTSTAMP:' || to_char(now() at time zone 'UTC', 'YYYYMMDD"T"HH24MISS"Z"') || chr(13) || chr(10) ||
      'DTSTART;VALUE=DATE:' || to_char(i.day, 'YYYYMMDD') || chr(13) || chr(10) ||
      -- Ganztägig: das Ende ist der Folgetag, sonst zeigt Outlook nichts an.
      'DTEND;VALUE=DATE:' || to_char(i.day + 1, 'YYYYMMDD') || chr(13) || chr(10) ||
      'SUMMARY:' || replace(replace(i.pkey || ' · ' || i.summary, chr(92), chr(92) || chr(92)), ',', chr(92) || ',') || chr(13) || chr(10) ||
      'DESCRIPTION:' || replace(replace(i.note, chr(92), chr(92) || chr(92)), ',', chr(92) || ',') || chr(13) || chr(10) ||
      'END:VEVENT', chr(13) || chr(10) order by i.day), '') ||
    chr(13) || chr(10) || 'END:VCALENDAR' end
  from items i;
$$;
comment on function pcc.calendar(uuid) is 'Offene Meilensteine und Aufgabenfristen als iCalendar-Text, zum Abonnieren oder Einlesen in Outlook.';
