-- =============================================================================
-- Project Control Center — Migration 3/5: Geschäftslogik
-- Audit, Registrierung und Freigabe, Projekte, Referenznummern, Versionierung,
-- Benachrichtigungen, Kommentare, Löschweg nach DSGVO, Tagesläufe
--
-- Fehlercodes sind mit PCC_ vorangestellt, damit die Oberfläche sie ohne
-- Textvergleich unterscheiden kann.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Audit. Ein Trail für die ganze Anwendung, gespeist aus Triggern.
-- -----------------------------------------------------------------------------
create or replace function pcc.tg_audit()
returns trigger
language plpgsql security definer set search_path = public, pcc as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_row jsonb := coalesce(v_new, v_old);
begin
  if tg_op = 'UPDATE' and v_old = v_new then
    return null;
  end if;
  insert into public.audit_log (user_id, project_id, entity, entity_id, action,
                                old_value, new_value, reason)
  values (auth.uid(),
          nullif(coalesce(v_row ->> 'project_id', case when tg_table_name = 'projects' then v_row ->> 'id' end), '')::uuid,
          'pcc.' || tg_table_name,
          coalesce(v_row ->> 'id', concat_ws(':', v_row ->> 'project_id', v_row ->> 'user_id',
                                             v_row ->> 'comment_id', v_row ->> 'key')),
          lower(tg_op), v_old, v_new,
          -- Die Begründung stammt aus einer Sitzungsvariablen. Übernommen wird
          -- sie nur, wenn der Schreibvorgang aus einer geprüften Funktion kommt
          -- — sonst könnte sich jeder eine Begründung erfinden.
          case when public.internal_write_enabled()
               then nullif(current_setting('app.audit_reason', true), '') end);
  return null;
end $$;

-- Rollenvergabe und Freigabe sind genau die Vorgänge, die ein Audit interessiert.
create trigger users_audit after insert or update or delete on public.users
  for each row execute function pcc.tg_audit();

do $$
declare t text;
begin
  foreach t in array array['projects','project_members','workstreams','tasks','milestones',
                           'risks','issues','decisions','documents','raci','comments',
                           'templates','settings','project_versions']
  loop
    execute format('create trigger %I_audit after insert or update or delete on pcc.%I for each row execute function pcc.tg_audit()', t, t);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Unveränderlichkeit
-- Der Audit-Trail kennt keine Ausnahme. Versionen schon: das endgültige Löschen
-- eines Projekts durch den Super Admin nimmt sie mit und hinterlässt selbst
-- einen Eintrag im Trail.
-- -----------------------------------------------------------------------------
create or replace function pcc.tg_immutable()
returns trigger
language plpgsql as $$
begin
  raise exception 'PCC_IMMUTABLE: % darf nicht geändert oder gelöscht werden', tg_table_name
    using errcode = 'P0001';
end $$;

create or replace function pcc.tg_immutable_unless_purge()
returns trigger
language plpgsql as $$
begin
  if public.internal_write_enabled() then
    return coalesce(new, old);
  end if;
  raise exception 'PCC_IMMUTABLE: % darf nicht geändert oder gelöscht werden', tg_table_name
    using errcode = 'P0001';
end $$;

create trigger project_versions_immutable before update or delete on pcc.project_versions
  for each row execute function pcc.tg_immutable_unless_purge();
create trigger version_changes_immutable before update or delete on pcc.version_changes
  for each row execute function pcc.tg_immutable_unless_purge();

-- -----------------------------------------------------------------------------
-- Referenznummern werden beim Anlegen vergeben und sind danach unveränderlich.
-- -----------------------------------------------------------------------------
create or replace function pcc.tg_set_ref()
returns trigger
language plpgsql security definer set search_path = public, pcc as $$
declare v_prefix text := tg_argv[0];
begin
  -- Immer aus dem Zähler, nie aus der Eingabe: eine frei gewählte Referenz
  -- könnte sonst mit der einer anderen Art kollidieren (ein Issue namens T-1).
  new.ref := pcc.next_ref(new.project_id, v_prefix);
  return new;
end $$;

create or replace function pcc.tg_ref_immutable()
returns trigger
language plpgsql as $$
begin
  if new.ref is distinct from old.ref then
    raise exception 'PCC_IMMUTABLE: Die Referenznummer eines Eintrags bleibt bestehen' using errcode = 'P0001';
  end if;
  if new.project_id is distinct from old.project_id then
    raise exception 'PCC_IMMUTABLE: Ein Eintrag wechselt nicht das Projekt' using errcode = 'P0001';
  end if;
  return new;
end $$;

create trigger tasks_ref before insert on pcc.tasks for each row execute function pcc.tg_set_ref('T');
create trigger milestones_ref before insert on pcc.milestones for each row execute function pcc.tg_set_ref('M');
create trigger risks_ref before insert on pcc.risks for each row execute function pcc.tg_set_ref('R');
create trigger issues_ref before insert on pcc.issues for each row execute function pcc.tg_set_ref('I');
create trigger decisions_ref before insert on pcc.decisions for each row execute function pcc.tg_set_ref('D');

do $$
declare t text;
begin
  foreach t in array array['tasks','milestones','risks','issues','decisions']
  loop
    execute format('create trigger %I_ref_immutable before update on pcc.%I for each row execute function pcc.tg_ref_immutable()', t, t);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Felder, die nicht der Oberfläche gehören
-- Der Versionszähler steckt in der Projektzeile. Setzt ihn jemand zurück,
-- kollidiert die nächste Version mit einer vorhandenen, und das Projekt lässt
-- sich fachlich nicht mehr fortschreiben. Archivieren und Löschen laufen über
-- Funktionen, die einen Grund verlangen.
-- -----------------------------------------------------------------------------
create or replace function pcc.tg_projects_guard()
returns trigger
language plpgsql as $$
begin
  if public.internal_write_enabled() then
    return new;
  end if;
  if new.key is distinct from old.key then
    raise exception 'PCC_IMMUTABLE: Der Projektschlüssel bleibt bestehen' using errcode = 'P0001';
  end if;
  if new.version_major is distinct from old.version_major
     or new.version_minor is distinct from old.version_minor then
    raise exception 'PCC_GUARD: Der Versionsstand wird von der Versionierung geführt' using errcode = 'P0001';
  end if;
  if new.archived_at is distinct from old.archived_at
     or new.archived_by is distinct from old.archived_by then
    raise exception 'PCC_GUARD: Archivieren nur über pcc.archive_project(), mit Grund' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger projects_guard before update on pcc.projects
  for each row execute function pcc.tg_projects_guard();

-- -----------------------------------------------------------------------------
-- Archiv ist schreibgeschützt (Abschnitt 41: verwerfen statt löschen).
-- -----------------------------------------------------------------------------
create or replace function pcc.tg_archived_guard()
returns trigger
language plpgsql security definer set search_path = public, pcc as $$
declare v_project uuid := coalesce(new.project_id, old.project_id);
begin
  if public.internal_write_enabled() then
    return coalesce(new, old);
  end if;
  if exists (select 1 from pcc.projects p where p.id = v_project and p.archived_at is not null) then
    raise exception 'PCC_ARCHIVED: Das Projekt ist archiviert und schreibgeschützt' using errcode = 'P0001';
  end if;
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['workstreams','tasks','milestones','risks','issues',
                           'decisions','documents','raci','comments','project_members']
  loop
    execute format('create trigger %I_archived_guard before insert or update or delete on pcc.%I for each row execute function pcc.tg_archived_guard()', t, t);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Statusabhängige Felder mitführen
-- -----------------------------------------------------------------------------
create or replace function pcc.tg_status_dates()
returns trigger
language plpgsql as $$
begin
  if tg_table_name = 'tasks' then
    if new.status = 'completed' and new.completed_at is null then
      new.completed_at := now();
      new.progress := 100;
    elsif new.status <> 'completed' then
      new.completed_at := null;
    end if;
  elsif tg_table_name = 'milestones' then
    if new.status = 'completed' and new.completed_at is null then
      new.completed_at := now();
    elsif new.status <> 'completed' then
      new.completed_at := null;
    end if;
    if new.baseline_date is null then
      new.baseline_date := new.due_date;
    end if;
  elsif tg_table_name = 'risks' then
    if new.status in ('closed', 'mitigated') and new.closed_at is null then
      new.closed_at := now();
    elsif new.status not in ('closed', 'mitigated') then
      new.closed_at := null;
    end if;
  elsif tg_table_name = 'issues' then
    if new.status in ('resolved', 'closed') and new.resolved_at is null then
      new.resolved_at := now();
    elsif new.status not in ('resolved', 'closed') then
      new.resolved_at := null;
    end if;
  end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['tasks','milestones','risks','issues']
  loop
    execute format('create trigger %I_status_dates before insert or update on pcc.%I for each row execute function pcc.tg_status_dates()', t, t);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Herkunftsspalten setzen und schützen
-- -----------------------------------------------------------------------------
-- „Angelegt von" wird gesetzt, nicht mitgeliefert. Sonst ließe sich eine
-- Meldung unter fremdem Namen einstellen.
create or replace function pcc.tg_created_by()
returns trigger
language plpgsql as $$
begin
  new.created_by := coalesce(auth.uid(), new.created_by);
  new.updated_by := new.created_by;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['templates','projects','workstreams','tasks','milestones',
                           'risks','issues','decisions','documents']
  loop
    execute format('create trigger %I_created_by before insert on pcc.%I for each row execute function pcc.tg_created_by()', t, t);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Versionierung (Abschnitt 6)
-- Eine Version entsteht nur bei fachlich bedeutsamen Ereignissen. Welche das
-- sind, steht in pcc.version_triggers und ist ohne Codeänderung erweiterbar.
-- -----------------------------------------------------------------------------
create or replace function pcc.new_version(
  p_project_id   uuid,
  p_trigger_code text,
  p_summary      text,
  p_changes      jsonb default '[]'::jsonb
)
returns uuid
language plpgsql security definer set search_path = public, pcc as $$
declare
  v_id      uuid;
  v_version text;
  v_change  jsonb;
begin
  if not exists (select 1 from pcc.version_triggers where code = p_trigger_code and active) then
    return null;   -- Ereignis ist als nicht versionswürdig konfiguriert
  end if;

  perform public.enable_internal_write();
  update pcc.projects
     set version_minor = version_minor + 1
   where id = p_project_id
  returning version_major || '.' || version_minor into v_version;
  perform public.disable_internal_write();

  insert into pcc.project_versions (project_id, version, trigger_code, summary, created_by)
  values (p_project_id, v_version, p_trigger_code, p_summary, auth.uid())
  returning id into v_id;

  for v_change in select * from jsonb_array_elements(coalesce(p_changes, '[]'::jsonb))
  loop
    insert into pcc.version_changes (version_id, entity_type, entity_id, entity_label, field, old_value, new_value)
    values (v_id,
            coalesce(v_change ->> 'entity_type', 'project')::pcc.entity_type,
            nullif(v_change ->> 'entity_id', '')::uuid,
            v_change ->> 'entity_label',
            v_change ->> 'field',
            v_change ->> 'old_value',
            v_change ->> 'new_value');
  end loop;
  return v_id;
end $$;

create or replace function pcc.tg_version_project()
returns trigger
language plpgsql security definer set search_path = public, pcc as $$
declare v_changes jsonb := '[]'::jsonb;
begin
  if pg_trigger_depth() > 1 then return null; end if;   -- eigener Zähler-Update

  if new.status is distinct from old.status then
    v_changes := jsonb_build_array(jsonb_build_object(
      'entity_type', 'project', 'entity_id', new.id, 'entity_label', new.name,
      'field', 'status', 'old_value', old.status::text, 'new_value', new.status::text));
    perform pcc.new_version(new.id, 'project_status',
      'Projektstatus geändert: ' || old.status::text || ' → ' || new.status::text, v_changes);
  end if;

  if new.target_end_date is distinct from old.target_end_date then
    v_changes := jsonb_build_array(jsonb_build_object(
      'entity_type', 'project', 'entity_id', new.id, 'entity_label', new.name,
      'field', 'target_end_date',
      'old_value', coalesce(old.target_end_date::text, '—'),
      'new_value', coalesce(new.target_end_date::text, '—')));
    perform pcc.new_version(new.id, 'project_end_date', 'Zieltermin des Projekts geändert', v_changes);
  end if;
  return null;
end $$;
create trigger projects_version after update on pcc.projects
  for each row execute function pcc.tg_version_project();

create or replace function pcc.tg_version_milestone()
returns trigger
language plpgsql security definer set search_path = public, pcc as $$
begin
  if new.due_date is distinct from old.due_date then
    perform pcc.new_version(new.project_id, 'milestone_moved',
      'Meilenstein verschoben: ' || new.name,
      jsonb_build_array(jsonb_build_object(
        'entity_type', 'milestone', 'entity_id', new.id, 'entity_label', new.name,
        'field', 'due_date', 'old_value', old.due_date::text, 'new_value', new.due_date::text)));
  end if;
  if new.status = 'completed' and old.status <> 'completed' then
    perform pcc.new_version(new.project_id, 'milestone_completed',
      'Meilenstein erreicht: ' || new.name,
      jsonb_build_array(jsonb_build_object(
        'entity_type', 'milestone', 'entity_id', new.id, 'entity_label', new.name,
        'field', 'status', 'old_value', old.status::text, 'new_value', new.status::text)));
  end if;
  return null;
end $$;
create trigger milestones_version after update on pcc.milestones
  for each row execute function pcc.tg_version_milestone();

create or replace function pcc.tg_version_risk()
returns trigger
language plpgsql security definer set search_path = public, pcc as $$
declare v_old_score smallint := case when tg_op = 'UPDATE' then old.score end;
begin
  if new.score >= 15 and coalesce(v_old_score, 0) < 15 and new.status in ('open', 'monitoring') then
    perform pcc.new_version(new.project_id, 'risk_critical',
      'Kritisches Risiko (Score ' || new.score || '): ' || new.title,
      jsonb_build_array(jsonb_build_object(
        'entity_type', 'risk', 'entity_id', new.id, 'entity_label', new.title,
        'field', 'score', 'old_value', coalesce(v_old_score::text, '—'), 'new_value', new.score::text)));
  end if;
  return null;
end $$;
create trigger risks_version after insert or update on pcc.risks
  for each row execute function pcc.tg_version_risk();

create or replace function pcc.tg_version_workstream()
returns trigger
language plpgsql security definer set search_path = public, pcc as $$
begin
  if new.completed_at is not null and old.completed_at is null then
    perform pcc.new_version(new.project_id, 'workstream_completed',
      'Workstream abgeschlossen: ' || new.name, '[]'::jsonb);
  end if;
  return null;
end $$;
create trigger workstreams_version after update on pcc.workstreams
  for each row execute function pcc.tg_version_workstream();

-- -----------------------------------------------------------------------------
-- Benachrichtigungen (Abschnitt 29)
-- -----------------------------------------------------------------------------
create or replace function pcc.notify(
  p_user_id uuid, p_project_id uuid, p_kind pcc.notification_kind,
  p_entity_type pcc.entity_type, p_entity_id uuid, p_title text, p_body text default null
)
returns void
language plpgsql security definer set search_path = public, pcc as $$
begin
  -- Sich selbst benachrichtigt niemand.
  if p_user_id is null or p_user_id = auth.uid() then return; end if;
  insert into pcc.notifications (user_id, project_id, kind, entity_type, entity_id, title, body)
  values (p_user_id, p_project_id, p_kind, p_entity_type, p_entity_id, p_title, p_body);
end $$;

create or replace function pcc.tg_notify_assignment()
returns trigger
language plpgsql security definer set search_path = public, pcc as $$
begin
  if new.assignee_user_id is not null
     and (tg_op = 'INSERT' or new.assignee_user_id is distinct from old.assignee_user_id) then
    perform pcc.notify(new.assignee_user_id, new.project_id, 'assigned', 'task', new.id,
      'Aufgabe zugewiesen: ' || new.ref || ' ' || new.title,
      case when new.due_date is not null then 'Fällig am ' || to_char(new.due_date, 'DD.MM.YYYY') end);
  end if;
  return null;
end $$;
create trigger tasks_notify after insert or update on pcc.tasks
  for each row execute function pcc.tg_notify_assignment();

create or replace function pcc.tg_notify_risk()
returns trigger
language plpgsql security definer set search_path = public, pcc as $$
declare v_pm uuid;
begin
  if new.score >= 15 and (tg_op = 'INSERT' or old.score < 15) and new.status in ('open', 'monitoring') then
    select pm_user_id into v_pm from pcc.projects where id = new.project_id;
    perform pcc.notify(v_pm, new.project_id, 'risk_critical', 'risk', new.id,
      'Kritisches Risiko: ' || new.ref || ' ' || new.title,
      'Score ' || new.score || ' (Eintritt ' || new.probability || ' × Auswirkung ' || new.impact || ')');
    perform pcc.notify(new.owner_user_id, new.project_id, 'risk_critical', 'risk', new.id,
      'Kritisches Risiko: ' || new.ref || ' ' || new.title, null);
  end if;
  return null;
end $$;
create trigger risks_notify after insert or update on pcc.risks
  for each row execute function pcc.tg_notify_risk();

create or replace function pcc.mark_notifications_read(p_ids uuid[] default null)
returns integer
language plpgsql security definer set search_path = public, pcc as $$
declare v_count integer;
begin
  update pcc.notifications
     set read_at = now()
   where user_id = auth.uid() and read_at is null
     and (p_ids is null or id = any(p_ids));
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- -----------------------------------------------------------------------------
-- Registrierung und Freigabe (Abschnitt 4)
-- Selbstregistrierung legt ein Konto ohne jede Rolle an. Ohne Freigabe durch
-- den Super Admin greift keine einzige Policy — der Nutzer sieht nichts.
-- -----------------------------------------------------------------------------
create or replace function public.tg_auth_user_registered()
returns trigger
language plpgsql security definer set search_path = public as $$
declare v_was_on boolean := public.internal_write_enabled();
begin
  -- Das Profil entsteht ohne Rolle und gesperrt. Es ist kein Anlegen durch
  -- einen Admin, deshalb der interne Schreibmodus um den Rollen-Guard herum.
  if not v_was_on then perform public.enable_internal_write(); end if;
  insert into public.users (id, name, email, active, pending, registered_at)
  values (new.id,
          coalesce(nullif(trim(new.email), ''), 'Neues Konto'),
          new.email, false, true, now())
  on conflict (id) do nothing;
  if not v_was_on then perform public.disable_internal_write(); end if;
  return new;
end $$;
comment on function public.tg_auth_user_registered() is
  'Selbstregistrierung: erzeugt ein Profil ohne Rolle, gesperrt bis zur Freigabe. Von Admins angelegte Konten überschreibt es nicht.';

create trigger auth_user_registered after insert on auth.users
  for each row execute function public.tg_auth_user_registered();

-- Rolle, Freigabe und Aktivstatus gehören nicht zu den Feldern, die jemand an
-- sich selbst ändern darf — sonst wäre die Selbstregistrierung ein Weg zum
-- Super Admin. Name und Sprache darf jeder an sich selbst pflegen.
create or replace function pcc.tg_users_role_guard()
returns trigger
language plpgsql security definer set search_path = public, pcc as $$
begin
  if public.internal_write_enabled() or pcc.is_super_admin() then
    return new;
  end if;
  if new.role is distinct from old.role
     or new.active is distinct from old.active
     or new.pending is distinct from old.pending
     or new.email is distinct from old.email
     or new.approved_at is distinct from old.approved_at
     or new.approved_by is distinct from old.approved_by then
    raise exception 'PCC_AUTH: Rolle, Freigabe und Zugang vergibt nur der Super Admin' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger users_pcc_role_guard before update on public.users
  for each row execute function pcc.tg_users_role_guard();

create or replace function pcc.approve_user(
  p_user_id uuid,
  p_role    pcc.user_role,
  p_name    text default null
)
returns public.users
language plpgsql security definer set search_path = public, pcc as $$
declare v_user public.users;
begin
  if not pcc.is_super_admin() then
    raise exception 'PCC_AUTH: Nur der Super Admin gibt Konten frei' using errcode = 'P0001';
  end if;
  perform public.enable_internal_write();
  update public.users
     set role    = p_role,
         name        = coalesce(nullif(trim(p_name), ''), name),
         active      = true,
         pending     = false,
         approved_at = now(),
         approved_by = auth.uid()
   where id = p_user_id
  returning * into v_user;
  perform public.disable_internal_write();
  if v_user.id is null then
    raise exception 'PCC_STATE: Konto nicht gefunden' using errcode = 'P0001';
  end if;
  perform pcc.notify(p_user_id, null, 'approval', null, null,
    'Ihr Zugang zum Project Control Center ist freigegeben', 'Rolle: ' || p_role::text);
  return v_user;
end $$;

-- Das erste Konto. Ohne Super Admin gibt es niemanden, der freigeben könnte —
-- und der Guard oben lässt auch im SQL-Editor keine Rollenvergabe durch, weil
-- dort niemand angemeldet ist. Deshalb ein eigener Weg, der genau einmal
-- funktioniert: Sobald ein aktiver Super Admin existiert, verweigert er sich.
-- Aufrufbar nur mit direktem Datenbankzugang, nicht über die API.
create or replace function pcc.bootstrap_super_admin(p_email text)
returns public.users
language plpgsql security definer set search_path = public, pcc as $$
declare v_user public.users;
begin
  if exists (select 1 from public.users where role = 'super_admin' and active) then
    raise exception 'PCC_STATE: Es gibt bereits einen Super Admin. Weitere Konten gibt dieser über pcc.approve_user() frei'
      using errcode = 'P0001';
  end if;
  perform public.enable_internal_write();
  update public.users
     set role = 'super_admin', active = true, pending = false, approved_at = now()
   where lower(email) = lower(trim(p_email))
  returning * into v_user;
  perform public.disable_internal_write();
  if v_user.id is null then
    raise exception 'PCC_STATE: Kein Konto mit der Adresse %. Erst anmelden, dann freischalten', p_email
      using errcode = 'P0001';
  end if;
  insert into public.audit_log (user_id, entity, entity_id, action, reason)
  values (v_user.id, 'public.users', v_user.id::text, 'bootstrap', 'Erster Super Admin bei der Inbetriebnahme');
  return v_user;
end $$;

create or replace function pcc.set_role(p_user_id uuid, p_role pcc.user_role)
returns public.users
language plpgsql security definer set search_path = public, pcc as $$
declare v_user public.users;
begin
  if not pcc.is_super_admin() then
    raise exception 'PCC_AUTH: Rollen vergibt nur der Super Admin' using errcode = 'P0001';
  end if;
  if p_user_id = auth.uid() and p_role is distinct from 'super_admin' then
    raise exception 'PCC_STATE: Der Super Admin kann sich nicht selbst herabstufen' using errcode = 'P0001';
  end if;
  perform public.enable_internal_write();
  update public.users set role = p_role where id = p_user_id returning * into v_user;
  perform public.disable_internal_write();
  return v_user;
end $$;

-- Artikel 17 DSGVO. Der Vorgang bleibt nachvollziehbar, die Person nicht mehr
-- erkennbar (docs/ARCHITECTURE.md Abschnitt 7b).
create or replace function pcc.anonymise_user(p_user_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public, pcc as $$
declare v_seq bigint;
begin
  if not pcc.is_super_admin() then
    raise exception 'PCC_AUTH: Nur der Super Admin führt ein Löschverlangen aus' using errcode = 'P0001';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'PCC_STATE: Für ein Löschverlangen ist eine Grundlage anzugeben' using errcode = 'P0001';
  end if;
  select count(*) + 1 into v_seq from public.users where name like 'Ehemaliger Mitarbeiter%';
  perform set_config('app.audit_reason', p_reason, true);
  perform public.enable_internal_write();
  update public.users
     set name       = 'Ehemaliger Mitarbeiter (' || v_seq || ')',
         email      = 'geloescht+' || p_user_id::text || '@invalid',
         active     = false,
         pending    = false,
         role       = null
   where id = p_user_id;
  perform public.disable_internal_write();
  insert into public.audit_log (user_id, entity, entity_id, action, reason)
  values (auth.uid(), 'public.users', p_user_id::text, 'anonymise', p_reason);
  perform set_config('app.audit_reason', '', true);
end $$;

-- -----------------------------------------------------------------------------
-- Projekte
-- -----------------------------------------------------------------------------
create or replace function pcc.create_project(
  p_key         text,
  p_name        text,
  p_pm_user_id  uuid default null,
  p_description text default null,
  p_objectives  text default null,
  p_scope       text default null,
  p_start_date  date default null,
  p_end_date    date default null,
  p_template_id uuid default null
)
returns pcc.projects
language plpgsql security definer set search_path = public, pcc as $$
declare
  v_project pcc.projects;
  v_pm      uuid := coalesce(p_pm_user_id, auth.uid());
  v_item    jsonb;
  v_ws_id   uuid;
  v_ws_map  jsonb := '{}'::jsonb;
begin
  if not (pcc.is_admin() or pcc.my_role() = 'pm') then
    raise exception 'PCC_AUTH: Projekte legen Projektleitung, Admin oder Super Admin an' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.users where id = v_pm and active and role is not null) then
    raise exception 'PCC_STATE: Die Projektleitung muss ein freigegebenes Konto im Control Center sein' using errcode = 'P0001';
  end if;

  insert into pcc.projects (key, name, description, objectives, scope, pm_user_id,
                            start_date, target_end_date, template_id, created_by, updated_by)
  values (upper(trim(p_key)), trim(p_name), p_description, p_objectives, p_scope, v_pm,
          p_start_date, p_end_date, p_template_id, auth.uid(), auth.uid())
  returning * into v_project;

  insert into pcc.project_members (project_id, user_id, project_role, responsibilities, created_by)
  values (v_project.id, v_pm, 'Project Manager', 'Gesamtsteuerung', auth.uid())
  on conflict do nothing;

  insert into pcc.project_versions (project_id, version, trigger_code, summary, created_by)
  values (v_project.id, '1.0', 'project_created', 'Projekt angelegt', auth.uid());

  -- Vorlage ausrollen (Abschnitt 30)
  if p_template_id is not null then
    for v_item in select * from jsonb_array_elements(
        coalesce((select payload -> 'workstreams' from pcc.templates where id = p_template_id), '[]'::jsonb))
    loop
      insert into pcc.workstreams (project_id, name, description, sort_order, created_by, updated_by)
      values (v_project.id, v_item ->> 'name', v_item ->> 'description',
              coalesce((v_item ->> 'sort_order')::smallint, 0), auth.uid(), auth.uid())
      returning id into v_ws_id;
      v_ws_map := v_ws_map || jsonb_build_object(v_item ->> 'name', v_ws_id::text);
    end loop;

    for v_item in select * from jsonb_array_elements(
        coalesce((select payload -> 'tasks' from pcc.templates where id = p_template_id), '[]'::jsonb))
    loop
      insert into pcc.tasks (project_id, workstream_id, title, description, priority,
                             due_date, created_by, updated_by)
      values (v_project.id,
              nullif(v_ws_map ->> (v_item ->> 'workstream'), '')::uuid,
              v_item ->> 'title', v_item ->> 'description',
              coalesce((v_item ->> 'priority')::pcc.priority, 'medium'),
              case when v_item ? 'due_offset_days' and p_start_date is not null
                   then p_start_date + (v_item ->> 'due_offset_days')::integer end,
              auth.uid(), auth.uid());
    end loop;

    for v_item in select * from jsonb_array_elements(
        coalesce((select payload -> 'milestones' from pcc.templates where id = p_template_id), '[]'::jsonb))
    loop
      insert into pcc.milestones (project_id, workstream_id, name, description, due_date, created_by, updated_by)
      values (v_project.id,
              nullif(v_ws_map ->> (v_item ->> 'workstream'), '')::uuid,
              v_item ->> 'name', v_item ->> 'description',
              coalesce(p_start_date, current_date) + coalesce((v_item ->> 'due_offset_days')::integer, 30),
              auth.uid(), auth.uid());
    end loop;
  end if;

  return v_project;
end $$;

create or replace function pcc.add_member(
  p_project_id uuid, p_user_id uuid, p_role text, p_responsibilities text default null
)
returns void
language plpgsql security definer set search_path = public, pcc as $$
begin
  if not pcc.can_edit(p_project_id) then
    raise exception 'PCC_AUTH: Das Projektteam pflegt die Projektleitung oder ein Admin' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.users where id = p_user_id and active and role is not null) then
    raise exception 'PCC_STATE: Nur freigegebene Konten können Projektmitglied sein' using errcode = 'P0001';
  end if;
  insert into pcc.project_members (project_id, user_id, project_role, responsibilities, created_by)
  values (p_project_id, p_user_id, p_role, p_responsibilities, auth.uid())
  on conflict (project_id, user_id)
    do update set project_role = excluded.project_role,
                  responsibilities = excluded.responsibilities;
  perform pcc.notify(p_user_id, p_project_id, 'assigned', 'project', p_project_id,
    'Sie wurden einem Projekt hinzugefügt', p_role);
end $$;

create or replace function pcc.archive_project(p_project_id uuid, p_reason text)
returns pcc.projects
language plpgsql security definer set search_path = public, pcc as $$
declare v_project pcc.projects;
begin
  if not pcc.can_edit(p_project_id) then
    raise exception 'PCC_AUTH: Archivieren darf die Projektleitung oder ein Admin' using errcode = 'P0001';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'PCC_STATE: Für das Archivieren ist ein Grund anzugeben' using errcode = 'P0001';
  end if;
  perform set_config('app.audit_reason', p_reason, true);
  perform public.enable_internal_write();
  update pcc.projects
     set archived_at = now(), archived_by = auth.uid()
   where id = p_project_id and archived_at is null
  returning * into v_project;
  perform public.disable_internal_write();
  perform set_config('app.audit_reason', '', true);
  if v_project.id is null then
    raise exception 'PCC_STATE: Projekt nicht gefunden oder bereits archiviert' using errcode = 'P0001';
  end if;
  return v_project;
end $$;

create or replace function pcc.unarchive_project(p_project_id uuid)
returns pcc.projects
language plpgsql security definer set search_path = public, pcc as $$
declare v_project pcc.projects;
begin
  if not pcc.is_admin() then
    raise exception 'PCC_AUTH: Aus dem Archiv holt ein Admin zurück' using errcode = 'P0001';
  end if;
  perform public.enable_internal_write();
  update pcc.projects set archived_at = null, archived_by = null
   where id = p_project_id returning * into v_project;
  perform public.disable_internal_write();
  return v_project;
end $$;

-- Endgültiges Löschen: ausschließlich Super Admin, nur mit Grund, mit Eintrag
-- im Trail. Der Trail selbst bleibt (Abschnitt 7b).
create or replace function pcc.delete_project(p_project_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public, pcc as $$
declare v_key text;
begin
  if not pcc.is_super_admin() then
    raise exception 'PCC_AUTH: Endgültiges Löschen ist dem Super Admin vorbehalten' using errcode = 'P0001';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'PCC_STATE: Für das Löschen ist ein Grund anzugeben' using errcode = 'P0001';
  end if;
  select key into v_key from pcc.projects where id = p_project_id;
  if v_key is null then
    raise exception 'PCC_STATE: Projekt nicht gefunden' using errcode = 'P0001';
  end if;
  perform public.enable_internal_write();
  perform set_config('app.audit_reason', p_reason, true);
  delete from pcc.projects where id = p_project_id;
  perform set_config('app.audit_reason', '', true);
  perform public.disable_internal_write();
  insert into public.audit_log (user_id, project_id, entity, entity_id, action, reason)
  values (auth.uid(), p_project_id, 'pcc.projects', v_key, 'purge', p_reason);
end $$;

-- -----------------------------------------------------------------------------
-- Kommentare und Erwähnungen (Abschnitte 28, 29)
-- -----------------------------------------------------------------------------
create or replace function pcc.post_comment(
  p_project_id  uuid,
  p_entity_type pcc.entity_type,
  p_entity_id   uuid,
  p_body        text,
  p_mentions    uuid[] default '{}'
)
returns pcc.comments
language plpgsql security definer set search_path = public, pcc as $$
declare
  v_comment pcc.comments;
  v_user    uuid;
begin
  if not pcc.can_contribute(p_project_id) then
    raise exception 'PCC_AUTH: In diesem Projekt haben Sie nur Leserecht' using errcode = 'P0001';
  end if;
  if coalesce(trim(p_body), '') = '' then
    raise exception 'PCC_STATE: Ein leerer Kommentar wird nicht gespeichert' using errcode = 'P0001';
  end if;
  insert into pcc.comments (project_id, entity_type, entity_id, user_id, body)
  values (p_project_id, p_entity_type, p_entity_id, auth.uid(), trim(p_body))
  returning * into v_comment;

  foreach v_user in array coalesce(p_mentions, '{}')
  loop
    -- Eine Erwähnung trägt den Anfang des Kommentars mit. Sie geht deshalb nur
    -- an Personen, die das Projekt ohnehin lesen dürfen.
    if exists (select 1 from public.users u
               where u.id = v_user and u.active and u.role is not null) then
      insert into pcc.mentions (comment_id, user_id) values (v_comment.id, v_user)
      on conflict do nothing;
      perform pcc.notify(v_user, p_project_id, 'mention', p_entity_type, p_entity_id,
        'Sie wurden erwähnt', left(trim(p_body), 140));
    end if;
  end loop;
  return v_comment;
end $$;

create or replace function pcc.delete_comment(p_comment_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public, pcc as $$
begin
  if not pcc.is_super_admin() then
    raise exception 'PCC_AUTH: Kommentare löscht auf Antrag nur der Super Admin' using errcode = 'P0001';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'PCC_STATE: Für die Löschung ist eine Grundlage anzugeben' using errcode = 'P0001';
  end if;
  perform set_config('app.audit_reason', p_reason, true);
  perform public.enable_internal_write();
  update pcc.comments
     set body = '(auf Antrag gelöscht)', deleted_at = now(),
         deleted_by = auth.uid(), deleted_reason = p_reason
   where id = p_comment_id;
  perform public.disable_internal_write();
  perform set_config('app.audit_reason', '', true);
end $$;

-- -----------------------------------------------------------------------------
-- Dokumente (Abschnitt 7a)
-- -----------------------------------------------------------------------------
create or replace function pcc.supersede_document(
  p_old_id uuid, p_title text, p_kind pcc.document_kind,
  p_storage_path text default null, p_external_url text default null,
  p_mime_type text default null, p_size_bytes bigint default null
)
returns pcc.documents
language plpgsql security definer set search_path = public, pcc as $$
declare
  v_old pcc.documents;
  v_new pcc.documents;
begin
  select * into v_old from pcc.documents where id = p_old_id;
  if v_old.id is null then
    raise exception 'PCC_STATE: Vorgängerdokument nicht gefunden' using errcode = 'P0001';
  end if;
  if not pcc.can_contribute(v_old.project_id) then
    raise exception 'PCC_AUTH: In diesem Projekt haben Sie nur Leserecht' using errcode = 'P0001';
  end if;
  perform public.enable_internal_write();
  insert into pcc.documents (project_id, entity_type, entity_id, title, description, kind,
                             storage_path, external_url, mime_type, size_bytes,
                             scan_state, version, supersedes_id, owner_user_id, created_by, updated_by)
  values (v_old.project_id, v_old.entity_type, v_old.entity_id,
          coalesce(nullif(trim(p_title), ''), v_old.title), v_old.description, p_kind,
          p_storage_path, p_external_url, p_mime_type, p_size_bytes,
          case when p_kind = 'file' then 'pending' else 'clean' end::pcc.scan_state,
          v_old.version + 1, v_old.id, auth.uid(), auth.uid(), auth.uid())
  returning * into v_new;
  perform public.disable_internal_write();
  return v_new;
end $$;
comment on function pcc.supersede_document is 'Ein Dokument wird nie überschrieben, sondern abgelöst. Der Stand zum Zeitpunkt eines Audits bleibt rekonstruierbar.';

-- -----------------------------------------------------------------------------
-- Dokumente: Quarantäne ist kein Vorschlag
-- Abschnitt 7a verlangt, dass eine hochgeladene Datei bis zur Virenprüfung als
-- „in Prüfung" gilt. Käme der Wert vom Client, wäre die Prüfung freiwillig.
-- -----------------------------------------------------------------------------
create or replace function pcc.tg_documents_guard()
returns trigger
language plpgsql as $$
begin
  if public.internal_write_enabled() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.scan_state := case when new.kind = 'file' then 'pending' else 'clean' end;
    new.version := coalesce(old.version, 1);
    new.supersedes_id := null;
    return new;
  end if;
  if new.scan_state is distinct from old.scan_state then
    raise exception 'PCC_GUARD: Den Prüfstand setzt die Virenprüfung, nicht die Oberfläche' using errcode = 'P0001';
  end if;
  if new.project_id is distinct from old.project_id then
    raise exception 'PCC_IMMUTABLE: Ein Dokument wechselt nicht das Projekt' using errcode = 'P0001';
  end if;
  if new.version is distinct from old.version or new.supersedes_id is distinct from old.supersedes_id then
    raise exception 'PCC_GUARD: Fassungen entstehen über pcc.supersede_document()' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger documents_guard before insert or update on pcc.documents
  for each row execute function pcc.tg_documents_guard();

-- Die Virenprüfung läuft als Edge Function unter service_role und meldet das
-- Ergebnis hierher zurück.
create or replace function pcc.set_scan_state(p_document_id uuid, p_state pcc.scan_state)
returns void
language plpgsql security definer set search_path = public, pcc as $$
begin
  perform public.enable_internal_write();
  update pcc.documents set scan_state = p_state where id = p_document_id;
  perform public.disable_internal_write();
end $$;

-- Ein Kommentar bleibt, wo er geschrieben wurde.
create or replace function pcc.tg_comments_guard()
returns trigger
language plpgsql as $$
begin
  if public.internal_write_enabled() then
    return new;
  end if;
  if new.project_id is distinct from old.project_id
     or new.entity_type is distinct from old.entity_type
     or new.entity_id is distinct from old.entity_id
     or new.user_id is distinct from old.user_id then
    raise exception 'PCC_IMMUTABLE: Ein Kommentar wechselt nicht den Gegenstand' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger comments_guard before update on pcc.comments
  for each row execute function pcc.tg_comments_guard();

-- Benachrichtigungen gehören dem System. Der Empfänger darf sie lesen und als
-- gelesen markieren — sonst nichts.
create or replace function pcc.tg_notifications_guard()
returns trigger
language plpgsql as $$
begin
  if public.internal_write_enabled() then
    return new;
  end if;
  if new.user_id is distinct from old.user_id or new.project_id is distinct from old.project_id
     or new.kind is distinct from old.kind or new.title is distinct from old.title
     or new.body is distinct from old.body or new.entity_type is distinct from old.entity_type
     or new.entity_id is distinct from old.entity_id
     or new.email_state is distinct from old.email_state then
    raise exception 'PCC_GUARD: An einer Benachrichtigung lässt sich nur der Lesestand ändern' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger notifications_guard before update on pcc.notifications
  for each row execute function pcc.tg_notifications_guard();

-- Teilaufgaben bleiben eine Ebene tief (Abschnitt 21). Eine Aufgabe, die
-- selbst schon Kind ist, kann kein Elternteil werden.
create or replace function pcc.tg_task_depth()
returns trigger
language plpgsql as $$
begin
  if new.parent_task_id is not null
     and exists (select 1 from pcc.tasks t
                 where t.id = new.parent_task_id and t.parent_task_id is not null) then
    raise exception 'PCC_STATE: Teilaufgaben gehen eine Ebene tief, nicht weiter' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger tasks_depth before insert or update on pcc.tasks
  for each row execute function pcc.tg_task_depth();

-- -----------------------------------------------------------------------------
-- Löschen ist kein gewöhnliches Ändern
-- Kommentare und Dokumente enthalten personenbezogene Daten. Entfernt werden
-- sie nur auf Antrag und nur durch den Super Admin, mit Grundlage im Trail
-- (Abschnitt 7b). Ohne diesen Riegel könnte der Eigentümer eines Dokuments es
-- über die gewöhnliche Schreibberechtigung stillschweigend verschwinden lassen.
-- -----------------------------------------------------------------------------
create or replace function pcc.tg_delete_guard()
returns trigger
language plpgsql as $$
begin
  if public.internal_write_enabled() then
    return new;
  end if;
  if new.deleted_at is distinct from old.deleted_at
     or new.deleted_by is distinct from old.deleted_by
     or new.deleted_reason is distinct from old.deleted_reason then
    raise exception 'PCC_AUTH: Löschen nur über die dafür vorgesehene Funktion, mit Grundlage'
      using errcode = 'P0001';
  end if;
  return new;
end $$;

create trigger documents_delete_guard before update on pcc.documents
  for each row execute function pcc.tg_delete_guard();
create trigger comments_delete_guard before update on pcc.comments
  for each row execute function pcc.tg_delete_guard();

-- Ein bearbeiteter Kommentar sagt das auch. Sonst ließe sich eine Aussage
-- nachträglich verändern, ohne dass es jemand sieht.
create or replace function pcc.tg_comment_edited()
returns trigger
language plpgsql as $$
begin
  if public.internal_write_enabled() then
    return new;
  end if;
  if new.body is distinct from old.body then
    new.edited_at := now();
  end if;
  return new;
end $$;
create trigger comments_edited before update on pcc.comments
  for each row execute function pcc.tg_comment_edited();

create or replace function pcc.delete_document(p_document_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public, pcc as $$
begin
  if not pcc.is_super_admin() then
    raise exception 'PCC_AUTH: Dokumente löscht auf Antrag nur der Super Admin' using errcode = 'P0001';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'PCC_STATE: Für die Löschung ist eine Grundlage anzugeben' using errcode = 'P0001';
  end if;
  perform set_config('app.audit_reason', p_reason, true);
  perform public.enable_internal_write();
  update pcc.documents
     set deleted_at = now(), deleted_by = auth.uid(), deleted_reason = p_reason
   where id = p_document_id;
  perform public.disable_internal_write();
  perform set_config('app.audit_reason', '', true);
end $$;
comment on function pcc.delete_document(uuid, text) is
  'Löschverlangen nach Artikel 17 DSGVO: die Datei wird als gelöscht geführt, der Vorgang bleibt im Trail.';

-- -----------------------------------------------------------------------------
-- Tageslauf: Fristen, überfällige Einträge, Meilensteinstatus
-- Auf Supabase über pg_cron, lokal manuell aufrufbar.
-- -----------------------------------------------------------------------------
create or replace function pcc.run_daily_jobs()
returns table (job text, affected integer)
language plpgsql security definer set search_path = public, pcc as $$
declare
  v_count integer;
  v_lead  integer := coalesce((select (value ->> 'due_soon_days')::integer from pcc.settings where key = 'reminders'), 3);
  r       record;
begin
  -- 1. Meilensteine, deren Termin verstrichen ist, gelten als verzögert
  perform public.enable_internal_write();
  update pcc.milestones
     set status = 'delayed'
   where status in ('planned', 'in_progress') and due_date < current_date;
  get diagnostics v_count = row_count;
  perform public.disable_internal_write();
  job := 'milestones_delayed'; affected := v_count; return next;

  -- 2. Aufgaben, die in v_lead Tagen fällig werden
  v_count := 0;
  for r in
    select t.id, t.project_id, t.assignee_user_id, t.ref, t.title, t.due_date
    from pcc.tasks t
    where t.status not in ('completed', 'cancelled')
      and t.assignee_user_id is not null
      and t.due_date = current_date + v_lead
      and not exists (
        select 1 from pcc.notifications n
        where n.user_id = t.assignee_user_id and n.entity_id = t.id
          and n.kind = 'due_soon' and n.created_at::date = current_date)
  loop
    insert into pcc.notifications (user_id, project_id, kind, entity_type, entity_id, title, body)
    values (r.assignee_user_id, r.project_id, 'due_soon', 'task', r.id,
            'Fällig in ' || v_lead || ' Tagen: ' || r.ref || ' ' || r.title,
            'Termin ' || to_char(r.due_date, 'DD.MM.YYYY'));
    v_count := v_count + 1;
  end loop;
  job := 'tasks_due_soon'; affected := v_count; return next;

  -- 3. Überfällige Aufgaben: Zuständiger und Projektleitung
  v_count := 0;
  for r in
    select t.id, t.project_id, t.assignee_user_id, t.ref, t.title, t.due_date, p.pm_user_id
    from pcc.tasks t join pcc.projects p on p.id = t.project_id
    where t.status not in ('completed', 'cancelled')
      and t.due_date < current_date
      and p.archived_at is null
      and not exists (
        select 1 from pcc.notifications n
        where n.entity_id = t.id and n.kind = 'overdue' and n.created_at::date = current_date)
  loop
    insert into pcc.notifications (user_id, project_id, kind, entity_type, entity_id, title, body)
    select u, r.project_id, 'overdue', 'task', r.id,
           'Überfällig: ' || r.ref || ' ' || r.title,
           'Termin war ' || to_char(r.due_date, 'DD.MM.YYYY')
    from unnest(array[r.assignee_user_id, r.pm_user_id]) u
    where u is not null
    group by u;
    v_count := v_count + 1;
  end loop;
  job := 'tasks_overdue'; affected := v_count; return next;
end $$;
