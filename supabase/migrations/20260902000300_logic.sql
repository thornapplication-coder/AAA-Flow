-- =============================================================================
-- AAA Flow — Migration 3/5: Geschäftslogik
-- Vorgangsanlage, Pool/Zuweisung, Prüfpunkte, Vier-Augen, Gate-Sperre,
-- Gate-3-Sperre, Ausnahmen, Verwerfen, Erinnerungen/Eskalation, Audit,
-- Kommunikation (Bearbeitungshistorie, Löschsperre, Erwähnungen)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Audit-Trail (generischer Trigger) — nicht löschbar, nicht editierbar
-- -----------------------------------------------------------------------------
create or replace function public.audit_write(
  p_entity text, p_entity_id text, p_action text,
  p_old jsonb, p_new jsonb, p_reason text default null, p_case_id uuid default null
) returns void
language sql security definer set search_path = public as $$
  insert into public.audit_log (user_id, case_id, entity, entity_id, action, old_value, new_value, reason)
  values (auth.uid(), p_case_id, p_entity, p_entity_id, p_action, p_old, p_new, p_reason);
$$;

create or replace function public.tg_audit()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_row jsonb := coalesce(v_new, v_old);
  v_case_id uuid;
  v_entity_id text;
begin
  if tg_op = 'UPDATE' and v_old = v_new then
    return null;
  end if;
  v_case_id := case
    when tg_table_name = 'cases' then (v_row ->> 'id')::uuid
    when v_row ? 'case_id' then (v_row ->> 'case_id')::uuid
    else null end;
  v_entity_id := coalesce(v_row ->> 'id', v_row ->> 'key',
                          concat_ws(':', v_row ->> 'case_id', v_row ->> 'gate_no', v_row ->> 'department',
                                         v_row ->> 'user_id', v_row ->> 'aircraft_type_id'));
  insert into public.audit_log (user_id, case_id, entity, entity_id, action, old_value, new_value, reason)
  values (auth.uid(), v_case_id, tg_table_name, v_entity_id, lower(tg_op), v_old, v_new,
          nullif(current_setting('app.audit_reason', true), ''));
  return null;
end $$;

create or replace function public.tg_immutable()
returns trigger
language plpgsql as $$
begin
  raise exception 'AAA_FLOW_IMMUTABLE: % darf nicht geändert oder gelöscht werden', tg_table_name
    using errcode = 'P0001';
end $$;

create trigger audit_log_immutable before update or delete on public.audit_log
  for each row execute function public.tg_immutable();
create trigger message_edits_immutable before update or delete on public.message_edits
  for each row execute function public.tg_immutable();

do $$
declare t text;
begin
  foreach t in array array['users','aircraft_types','type_assignments','deputies','companies','trainees',
                           'checkpoints','cases','case_assignments','gates','case_checkpoints','exceptions',
                           'settings']
  loop
    execute format('create trigger %I_audit after insert or update or delete on public.%I for each row execute function public.tg_audit()', t, t);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Guard-Trigger: Status, Gates, Zuweisungen und Prüfpunkte nur über Funktionen
-- -----------------------------------------------------------------------------
create or replace function public.tg_cases_guard()
returns trigger
language plpgsql as $$
begin
  if public.internal_write_enabled() then
    return new;
  end if;
  if new.status is distinct from old.status then
    raise exception 'AAA_FLOW_GUARD: Statuswechsel nur über release_gate() oder discard_case()' using errcode = 'P0001';
  end if;
  if old.status in ('completed', 'discarded') then
    raise exception 'AAA_FLOW_GUARD: Abgeschlossene oder verworfene Vorgänge sind schreibgeschützt' using errcode = 'P0001';
  end if;
  if new.closed_reason is distinct from old.closed_reason then
    raise exception 'AAA_FLOW_GUARD: closed_reason nur über discard_case()' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger cases_guard before update on public.cases
  for each row execute function public.tg_cases_guard();

create or replace function public.tg_internal_only()
returns trigger
language plpgsql as $$
begin
  if public.internal_write_enabled() then
    return coalesce(new, old);
  end if;
  raise exception 'AAA_FLOW_GUARD: % wird ausschließlich über Geschäftslogik-Funktionen geschrieben', tg_table_name
    using errcode = 'P0001';
end $$;
create trigger gates_internal before insert or update or delete on public.gates
  for each row execute function public.tg_internal_only();
create trigger case_assignments_internal before insert or update or delete on public.case_assignments
  for each row execute function public.tg_internal_only();
create trigger case_checkpoints_internal before insert or update or delete on public.case_checkpoints
  for each row execute function public.tg_internal_only();
create trigger exceptions_internal before insert or update or delete on public.exceptions
  for each row execute function public.tg_internal_only();

-- Nutzer dürfen an sich selbst nur Sprache und Name ändern
create or replace function public.tg_users_self_guard()
returns trigger
language plpgsql as $$
begin
  if public.is_superadmin() or public.is_admin() or public.internal_write_enabled() then
    return new;
  end if;
  if new.role <> old.role or new.department <> old.department or new.active <> old.active
     or new.email <> old.email then
    raise exception 'AAA_FLOW_GUARD: Rolle, Abteilung, E-Mail und Aktivstatus ändert nur ein Admin' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger users_self_guard before update on public.users
  for each row execute function public.tg_users_self_guard();

-- Admin (nicht Superadmin) darf keine Nutzer anlegen und Rollen nicht auf superadmin heben
create or replace function public.tg_users_role_guard()
returns trigger
language plpgsql as $$
begin
  if public.internal_write_enabled() then return new; end if;
  if tg_op = 'INSERT' and not public.is_superadmin() then
    raise exception 'AAA_FLOW_GUARD: Nutzeranlage nur durch Superadmin' using errcode = 'P0001';
  end if;
  if tg_op = 'UPDATE' and new.role = 'superadmin' and old.role <> 'superadmin' and not public.is_superadmin() then
    raise exception 'AAA_FLOW_GUARD: Superadmin-Rolle vergibt nur ein Superadmin' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger users_role_guard before insert or update on public.users
  for each row execute function public.tg_users_role_guard();

-- -----------------------------------------------------------------------------
-- Vorgangsnummer AF-JJJJ-NNNN
-- -----------------------------------------------------------------------------
create or replace function public.tg_case_number()
returns trigger
language plpgsql as $$
begin
  if new.case_number is null or new.case_number = '' then
    new.case_number := format('AF-%s-%s', to_char(now(), 'YYYY'), lpad(nextval('public.case_number_seq')::text, 4, '0'));
  end if;
  if new.created_by is null then
    new.created_by := auth.uid();
  end if;
  return new;
end $$;
create trigger cases_number before insert on public.cases
  for each row execute function public.tg_case_number();

-- -----------------------------------------------------------------------------
-- Fristen: Anker Kursbeginn (rückwärts), Anfragedatum/Kursende (vorwärts)
-- -----------------------------------------------------------------------------
create or replace function public.compute_due_date(p_checkpoint public.checkpoints, p_case public.cases)
returns date
language sql immutable as $$
  select case
    when p_checkpoint.deadline_days is null then null
    when p_checkpoint.deadline_anchor = 'enquiry_date' then public.add_business_days(p_case.enquiry_date, p_checkpoint.deadline_days)
    when p_checkpoint.deadline_anchor = 'course_end'   then public.add_business_days(p_case.course_end, p_checkpoint.deadline_days)
    else public.add_business_days(p_case.course_start, -p_checkpoint.deadline_days)
  end;
$$;

create or replace function public.recompute_due_dates(p_case_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_case public.cases;
begin
  select * into v_case from public.cases where id = p_case_id;
  update public.case_checkpoints cc
     set due_at = public.compute_due_date(cp, v_case)
    from public.checkpoints cp
   where cp.id = cc.checkpoint_id
     and cc.case_id = p_case_id
     and cc.status <> 'verified';
end $$;

-- -----------------------------------------------------------------------------
-- Vorgangsanlage: Gates, Prüfpunkte (Snapshot aus Katalog), Zuständigkeiten
-- -----------------------------------------------------------------------------
create or replace function public.instantiate_case_checkpoints(p_case_id uuid)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_case public.cases;
  v_count integer;
begin
  select * into v_case from public.cases where id = p_case_id;
  insert into public.case_checkpoints (case_id, checkpoint_id, due_at)
  select v_case.id, cp.id, public.compute_due_date(cp, v_case)
  from public.checkpoints cp
  where cp.active
    and (cp.aircraft_type_filter is null or v_case.aircraft_type_id = any (cp.aircraft_type_filter))
  on conflict (case_id, checkpoint_id) do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- ATO: Course Supervisor der Flotte, sonst Head of Training (Spec 8, Fallback)
create or replace function public.resolve_ato_responsible(p_aircraft_type_id uuid)
returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select ta.user_id
       from public.type_assignments ta
       join public.users u on u.id = ta.user_id and u.active and u.department = 'ato'
      where ta.aircraft_type_id = p_aircraft_type_id and ta.department = 'ato'
      order by u.name
      limit 1),
    public.function_holder('head_of_training')
  );
$$;

create or replace function public.tg_case_after_insert()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_creator public.users;
  v_sales_user uuid;
  v_ato_user uuid;
  v_was_on boolean;
begin
  v_was_on := public.internal_write_enabled();
  perform public.enable_internal_write();
  select * into v_creator from public.users where id = new.created_by;

  insert into public.gates (case_id, gate_no) values (new.id, 1), (new.id, 2), (new.id, 3);

  -- Sales: Anleger übernimmt, wenn er aus Sales kommt; sonst Pool
  v_sales_user := case when v_creator.department = 'sales' then v_creator.id end;
  -- ATO: automatisch über das Muster
  v_ato_user := public.resolve_ato_responsible(new.aircraft_type_id);

  insert into public.case_assignments (case_id, department, user_id, assigned_at) values
    (new.id, 'sales',          v_sales_user, case when v_sales_user is not null then now() end),
    (new.id, 'training_admin', null,         null),
    (new.id, 'ato',            v_ato_user,   case when v_ato_user is not null then now() end);

  perform public.instantiate_case_checkpoints(new.id);
  if not v_was_on then perform public.disable_internal_write(); end if;
  return null;
end $$;
create trigger cases_after_insert after insert on public.cases
  for each row execute function public.tg_case_after_insert();

create or replace function public.tg_case_after_update()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_was_on boolean := public.internal_write_enabled();
begin
  if new.course_start is distinct from old.course_start
     or new.course_end is distinct from old.course_end
     or new.enquiry_date is distinct from old.enquiry_date then
    perform public.enable_internal_write();
    perform public.recompute_due_dates(new.id);
    if not v_was_on then perform public.disable_internal_write(); end if;
  end if;
  return null;
end $$;
create trigger cases_after_update after update on public.cases
  for each row execute function public.tg_case_after_update();

-- -----------------------------------------------------------------------------
-- Vorgang anlegen (empfohlener Pfad für Clients). Ein direkter INSERT ist per
-- RLS ebenfalls möglich, liefert aber kein RETURNING, weil die Zuständigkeit
-- erst der AFTER-Trigger setzt.
-- -----------------------------------------------------------------------------
create or replace function public.create_case(
  p_trainee_id uuid,
  p_company_id uuid,
  p_aircraft_type_id uuid,
  p_course_type text,
  p_enquiry_date date default current_date,
  p_course_start date default null,
  p_course_end date default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_me public.users := public.me();
  v_id uuid;
begin
  if v_me.id is null then raise exception 'AAA_FLOW_AUTH: kein aktiver Nutzer' using errcode = '42501'; end if;
  if not (v_me.department in ('sales', 'training_admin') or v_me.role in ('superadmin', 'admin', 'teamleader')) then
    raise exception 'AAA_FLOW_AUTH: Vorgänge legen Sales oder Training Admin an' using errcode = '42501';
  end if;
  if v_me.department = 'sales' and v_me.role = 'staff' and not public.is_function_holder('sales_lead')
     and p_aircraft_type_id not in (select public.my_aircraft_type_ids()) then
    raise exception 'AAA_FLOW_AUTH: Sales legt nur Vorgänge der zugeordneten Muster an' using errcode = '42501';
  end if;
  insert into public.cases (trainee_id, company_id, aircraft_type_id, course_type, enquiry_date, course_start, course_end, created_by)
  values (p_trainee_id, p_company_id, p_aircraft_type_id, p_course_type, coalesce(p_enquiry_date, current_date), p_course_start, p_course_end, v_me.id)
  returning id into v_id;
  return v_id;
end $$;

-- -----------------------------------------------------------------------------
-- Benachrichtigung (In-App; E-Mail-Versand übernimmt eine Edge Function, die
-- notifications mit email_status = 'pending' abarbeitet)
-- -----------------------------------------------------------------------------
create or replace function public.notify(
  p_user_id uuid, p_case_id uuid, p_type public.notification_type, p_payload jsonb default '{}'::jsonb
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_user_id is null then return; end if;
  insert into public.notifications (user_id, case_id, type, payload)
  values (p_user_id, p_case_id, p_type, coalesce(p_payload, '{}'::jsonb));
end $$;

create or replace function public.notify_department(
  p_department public.department, p_case_id uuid, p_type public.notification_type, p_payload jsonb default '{}'::jsonb,
  p_role public.user_role default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, case_id, type, payload)
  select u.id, p_case_id, p_type, coalesce(p_payload, '{}'::jsonb)
  from public.users u
  where u.active and u.department = p_department
    and (p_role is null or u.role = p_role);
end $$;

-- -----------------------------------------------------------------------------
-- Pool und Zuweisung (Pull-Prinzip, Spec 8)
-- -----------------------------------------------------------------------------
create or replace function public.claim_case(p_case_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_me public.users := public.me();
  v_assignment public.case_assignments;
begin
  if v_me.id is null then raise exception 'AAA_FLOW_AUTH: kein aktiver Nutzer' using errcode = '42501'; end if;
  if not public.can_view_case(p_case_id) then
    raise exception 'AAA_FLOW_AUTH: Vorgang nicht sichtbar' using errcode = '42501';
  end if;
  select * into v_assignment from public.case_assignments
   where case_id = p_case_id and department = v_me.department for update;
  if v_assignment.case_id is null then
    raise exception 'AAA_FLOW_STATE: keine Zuständigkeit für diese Abteilung' using errcode = 'P0001';
  end if;
  if v_assignment.user_id is not null then
    raise exception 'AAA_FLOW_STATE: Vorgang ist bereits übernommen' using errcode = 'P0001';
  end if;
  perform public.enable_internal_write();
  update public.case_assignments
     set user_id = v_me.id, assigned_at = now()
   where case_id = p_case_id and department = v_me.department;
  perform public.disable_internal_write();
end $$;

create or replace function public.assign_case(p_case_id uuid, p_department public.department, p_user_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_target public.users;
begin
  if not (public.is_admin() or public.is_teamleader_of(p_department)) then
    raise exception 'AAA_FLOW_AUTH: Zuweisung nur durch Teamleader der Abteilung oder Admin' using errcode = '42501';
  end if;
  select * into v_target from public.users where id = p_user_id and active;
  if v_target.id is null or v_target.department <> p_department then
    raise exception 'AAA_FLOW_STATE: Zielnutzer nicht aktiv oder nicht in Abteilung %', p_department using errcode = 'P0001';
  end if;
  perform public.enable_internal_write();
  update public.case_assignments
     set user_id = p_user_id, assigned_at = now()
   where case_id = p_case_id and department = p_department;
  if not found then
    raise exception 'AAA_FLOW_STATE: Vorgang oder Abteilung unbekannt' using errcode = 'P0001';
  end if;
  perform public.notify(p_user_id, p_case_id, 'assignment', jsonb_build_object('department', p_department));
  perform public.disable_internal_write();
end $$;

create or replace function public.release_to_pool(p_case_id uuid, p_department public.department)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_admin() or public.is_teamleader_of(p_department) or public.is_responsible(p_case_id, p_department)) then
    raise exception 'AAA_FLOW_AUTH: nur Zuständiger, Teamleader oder Admin' using errcode = '42501';
  end if;
  perform public.enable_internal_write();
  update public.case_assignments
     set user_id = null, assigned_at = null, pool_since = now(), stale_notified_at = null
   where case_id = p_case_id and department = p_department;
  perform public.disable_internal_write();
end $$;

-- Liegenbleiber-Regel (Spec 8): nach N Arbeitstagen im Pool an Teamleader zur Zuweisung
create or replace function public.escalate_stale_pool()
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_days integer := coalesce((select (value ->> 'business_days')::integer from public.settings where key = 'pool_stale'), 2);
  v_count integer := 0;
  r record;
begin
  perform public.enable_internal_write();
  for r in
    select ca.case_id, ca.department
    from public.case_assignments ca
    join public.cases c on c.id = ca.case_id
    where ca.user_id is null
      and ca.stale_notified_at is null
      and c.status not in ('completed', 'discarded')
      and public.business_days_between(ca.pool_since::date, current_date) >= v_days
  loop
    perform public.notify_department(r.department, r.case_id, 'pool_stale',
      jsonb_build_object('department', r.department, 'business_days', v_days), 'teamleader');
    update public.case_assignments set stale_notified_at = now()
     where case_id = r.case_id and department = r.department;
    v_count := v_count + 1;
  end loop;
  perform public.disable_internal_write();
  return v_count;
end $$;

-- -----------------------------------------------------------------------------
-- Prüfpunkte: erledigen, kontrollieren (Vier-Augen), zurücksetzen
-- -----------------------------------------------------------------------------
create or replace function public.checkpoint_is_done(p_case_id uuid, p_checkpoint_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.case_checkpoints cc
    where cc.case_id = p_case_id and cc.checkpoint_id = p_checkpoint_id and cc.status = 'verified'
  ) or exists (
    select 1 from public.exceptions e
    where e.case_id = p_case_id and e.checkpoint_id = p_checkpoint_id and e.status = 'approved'
  );
$$;

-- Offene Pflichtpunkte eines Gates (ohne genehmigte Ausnahme)
create or replace function public.open_mandatory_checkpoints(p_case_id uuid, p_gate_no integer, p_exclude_checkpoint uuid default null)
returns setof public.case_checkpoints
language sql stable security definer set search_path = public as $$
  select cc.*
  from public.case_checkpoints cc
  join public.checkpoints cp on cp.id = cc.checkpoint_id
  where cc.case_id = p_case_id
    and cp.gate_no = p_gate_no
    and cp.mandatory
    and (p_exclude_checkpoint is null or cp.id <> p_exclude_checkpoint)
    and not public.checkpoint_is_done(p_case_id, cp.id);
$$;

create or replace function public.complete_checkpoint(p_case_checkpoint_id uuid, p_note text default null)
returns public.case_checkpoints
language plpgsql security definer set search_path = public as $$
declare
  v_me public.users := public.me();
  v_cc public.case_checkpoints;
  v_cp public.checkpoints;
  v_case public.cases;
  v_prev_gate public.gate_state;
  v_open integer;
begin
  if v_me.id is null then raise exception 'AAA_FLOW_AUTH: kein aktiver Nutzer' using errcode = '42501'; end if;
  select * into v_cc from public.case_checkpoints where id = p_case_checkpoint_id for update;
  if v_cc.id is null then raise exception 'AAA_FLOW_STATE: Prüfpunkt unbekannt' using errcode = 'P0001'; end if;
  select * into v_cp from public.checkpoints where id = v_cc.checkpoint_id;
  select * into v_case from public.cases where id = v_cc.case_id;

  if v_case.status in ('completed', 'discarded') then
    raise exception 'AAA_FLOW_STATE: Vorgang ist abgeschlossen oder verworfen' using errcode = 'P0001';
  end if;
  -- Sichtbarkeit ist nicht Berechtigung (Spec 9): nur der Zuständige der Abteilung (oder Admin)
  if not (public.is_responsible(v_cc.case_id, v_cp.department) or public.is_admin()) then
    raise exception 'AAA_FLOW_AUTH: nur der Zuständige der Abteilung % darf diesen Prüfpunkt erledigen', v_cp.department
      using errcode = '42501';
  end if;
  if v_cc.status <> 'open' then
    raise exception 'AAA_FLOW_STATE: Prüfpunkt ist bereits erledigt' using errcode = 'P0001';
  end if;
  -- Gate-Sperre: Prüfpunkte eines Gates erst nach Freigabe des vorherigen Gates
  if v_cp.gate_no > 1 then
    select status into v_prev_gate from public.gates where case_id = v_cc.case_id and gate_no = v_cp.gate_no - 1;
    if v_prev_gate <> 'released' then
      raise exception 'AAA_FLOW_GATE: Gate % ist noch nicht freigegeben', v_cp.gate_no - 1 using errcode = 'P0001';
    end if;
  end if;
  -- Gate-3-Sperre (Spec 15, Punkt 1): kein Abschlussnachweis, solange Pflicht-Records fehlen
  if v_cp.requires_gate_complete then
    select count(*) into v_open from public.open_mandatory_checkpoints(v_cc.case_id, v_cp.gate_no, v_cp.id);
    if v_open > 0 then
      raise exception 'AAA_FLOW_GATE: % Pflichtpunkt(e) in Gate % offen — "%" ist gesperrt', v_open, v_cp.gate_no, v_cp.label_de
        using errcode = 'P0001';
    end if;
  end if;

  perform public.enable_internal_write();
  update public.case_checkpoints
     set status = case when v_cp.four_eyes then 'completed'::public.checkpoint_state else 'verified'::public.checkpoint_state end,
         completed_by = v_me.id,
         completed_at = now(),
         verified_at = case when v_cp.four_eyes then null else now() end,
         note = coalesce(p_note, note)
   where id = v_cc.id
   returning * into v_cc;
  update public.gates set status = 'in_progress'
   where case_id = v_cc.case_id and gate_no = v_cp.gate_no and status = 'open';
  perform public.disable_internal_write();
  return v_cc;
end $$;

create or replace function public.verify_checkpoint(p_case_checkpoint_id uuid, p_note text default null)
returns public.case_checkpoints
language plpgsql security definer set search_path = public as $$
declare
  v_me public.users := public.me();
  v_cc public.case_checkpoints;
  v_cp public.checkpoints;
begin
  if v_me.id is null then raise exception 'AAA_FLOW_AUTH: kein aktiver Nutzer' using errcode = '42501'; end if;
  select * into v_cc from public.case_checkpoints where id = p_case_checkpoint_id for update;
  if v_cc.id is null then raise exception 'AAA_FLOW_STATE: Prüfpunkt unbekannt' using errcode = 'P0001'; end if;
  select * into v_cp from public.checkpoints where id = v_cc.checkpoint_id;
  if not v_cp.four_eyes then
    raise exception 'AAA_FLOW_STATE: Prüfpunkt hat keine Vier-Augen-Anforderung' using errcode = 'P0001';
  end if;
  if v_cc.status <> 'completed' then
    raise exception 'AAA_FLOW_STATE: Prüfpunkt ist nicht zur Kontrolle bereit' using errcode = 'P0001';
  end if;
  -- Vier-Augen-Prinzip (Spec 10): hart erzwungen, gilt auch für Vertretungen und Admins
  if v_cc.completed_by = v_me.id then
    raise exception 'AAA_FLOW_FOUR_EYES: Kontrolle nicht durch dieselbe Person wie die Bearbeitung' using errcode = 'P0001';
  end if;
  if not (public.is_admin() or (v_me.department = v_cp.department)) then
    raise exception 'AAA_FLOW_AUTH: Kontrolle nur durch Abteilung % oder Admin', v_cp.department using errcode = '42501';
  end if;
  perform public.enable_internal_write();
  update public.case_checkpoints
     set status = 'verified', verified_by = v_me.id, verified_at = now(), note = coalesce(p_note, note)
   where id = v_cc.id
   returning * into v_cc;
  perform public.disable_internal_write();
  return v_cc;
end $$;

create or replace function public.reset_checkpoint(p_case_checkpoint_id uuid, p_reason text)
returns public.case_checkpoints
language plpgsql security definer set search_path = public as $$
declare
  v_me public.users := public.me();
  v_cc public.case_checkpoints;
  v_cp public.checkpoints;
  v_gate public.gate_state;
begin
  if v_me.id is null then raise exception 'AAA_FLOW_AUTH: kein aktiver Nutzer' using errcode = '42501'; end if;
  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception 'AAA_FLOW_STATE: Zurücksetzen erfordert eine Begründung' using errcode = 'P0001';
  end if;
  select * into v_cc from public.case_checkpoints where id = p_case_checkpoint_id for update;
  if v_cc.id is null then raise exception 'AAA_FLOW_STATE: Prüfpunkt unbekannt' using errcode = 'P0001'; end if;
  select * into v_cp from public.checkpoints where id = v_cc.checkpoint_id;
  if not (public.is_admin() or public.is_teamleader_of(v_cp.department) or public.is_responsible(v_cc.case_id, v_cp.department)) then
    raise exception 'AAA_FLOW_AUTH: nur Zuständiger, Teamleader der Abteilung oder Admin' using errcode = '42501';
  end if;
  if v_cc.status = 'open' then
    raise exception 'AAA_FLOW_STATE: Prüfpunkt ist bereits offen' using errcode = 'P0001';
  end if;
  select status into v_gate from public.gates where case_id = v_cc.case_id and gate_no = v_cp.gate_no;
  if v_gate = 'released' then
    raise exception 'AAA_FLOW_GATE: Gate % ist bereits freigegeben; Prüfpunkt kann nicht zurückgesetzt werden', v_cp.gate_no
      using errcode = 'P0001';
  end if;
  perform public.enable_internal_write();
  perform set_config('app.audit_reason', p_reason, true);
  update public.case_checkpoints
     set status = 'open', completed_by = null, completed_at = null, verified_by = null, verified_at = null
   where id = v_cc.id
   returning * into v_cc;
  perform set_config('app.audit_reason', '', true);
  perform public.disable_internal_write();
  return v_cc;
end $$;

-- -----------------------------------------------------------------------------
-- Gate-Freigabe (Spec 7): freigibt, wer die Arbeit empfängt
-- -----------------------------------------------------------------------------
create or replace function public.release_gate(p_case_id uuid, p_gate_no integer)
returns public.gates
language plpgsql security definer set search_path = public as $$
declare
  v_me public.users := public.me();
  v_case public.cases;
  v_gate public.gates;
  v_dept public.department := public.gate_release_department(p_gate_no);
  v_prev public.gate_state;
  v_open integer;
  v_new_status public.case_status;
begin
  if v_me.id is null then raise exception 'AAA_FLOW_AUTH: kein aktiver Nutzer' using errcode = '42501'; end if;
  select * into v_case from public.cases where id = p_case_id for update;
  if v_case.id is null then raise exception 'AAA_FLOW_STATE: Vorgang unbekannt' using errcode = 'P0001'; end if;
  if v_case.status in ('completed', 'discarded') then
    raise exception 'AAA_FLOW_STATE: Vorgang ist abgeschlossen oder verworfen' using errcode = 'P0001';
  end if;
  select * into v_gate from public.gates where case_id = p_case_id and gate_no = p_gate_no for update;
  if v_gate.status = 'released' then
    raise exception 'AAA_FLOW_STATE: Gate % ist bereits freigegeben', p_gate_no using errcode = 'P0001';
  end if;
  if not (public.is_admin() or public.is_teamleader_of(v_dept) or public.is_responsible(p_case_id, v_dept)) then
    raise exception 'AAA_FLOW_AUTH: Gate % gibt ausschließlich % frei', p_gate_no, v_dept using errcode = '42501';
  end if;
  if p_gate_no > 1 then
    select status into v_prev from public.gates where case_id = p_case_id and gate_no = p_gate_no - 1;
    if v_prev <> 'released' then
      raise exception 'AAA_FLOW_GATE: Gate % ist noch nicht freigegeben', p_gate_no - 1 using errcode = 'P0001';
    end if;
  end if;
  if p_gate_no = 1 and v_case.course_start is null then
    raise exception 'AAA_FLOW_GATE: Gate 1 erfordert ein fixiertes Kursdatum' using errcode = 'P0001';
  end if;
  if p_gate_no = 3 and (v_case.course_end is null or v_case.course_end > current_date) then
    raise exception 'AAA_FLOW_GATE: Gate 3 kann erst nach Kursende freigegeben werden' using errcode = 'P0001';
  end if;
  select count(*) into v_open from public.open_mandatory_checkpoints(p_case_id, p_gate_no);
  if v_open > 0 then
    raise exception 'AAA_FLOW_GATE: % Pflichtpunkt(e) in Gate % offen', v_open, p_gate_no using errcode = 'P0001';
  end if;

  v_new_status := case p_gate_no when 1 then 'booked' when 2 then 'released' when 3 then 'completed' end;
  if p_gate_no = 2 and v_case.course_start <= current_date then
    v_new_status := 'in_progress';
  end if;

  perform public.enable_internal_write();
  update public.gates set status = 'released', released_by = v_me.id, released_at = now()
   where case_id = p_case_id and gate_no = p_gate_no
   returning * into v_gate;
  update public.cases set status = v_new_status where id = p_case_id;

  -- Nächste Abteilung informieren: alle Zuständigen des Vorgangs
  insert into public.notifications (user_id, case_id, type, payload)
  select ca.user_id, p_case_id, 'gate_released', jsonb_build_object('gate_no', p_gate_no, 'status', v_new_status)
  from public.case_assignments ca
  where ca.case_id = p_case_id and ca.user_id is not null and ca.user_id <> v_me.id;
  perform public.disable_internal_write();
  return v_gate;
end $$;

-- Status "In Durchführung" bei Kursbeginn (Cron, täglich)
create or replace function public.advance_in_progress()
returns integer
language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  perform public.enable_internal_write();
  update public.cases set status = 'in_progress'
   where status = 'released' and course_start <= current_date;
  get diagnostics v_count = row_count;
  perform public.disable_internal_write();
  return v_count;
end $$;

-- -----------------------------------------------------------------------------
-- Verwerfen (Spec 6): Pflichtangabe Grund
-- -----------------------------------------------------------------------------
create or replace function public.discard_case(p_case_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception 'AAA_FLOW_STATE: Verwerfen erfordert eine Begründung' using errcode = 'P0001';
  end if;
  if not (public.is_admin() or public.my_role() = 'teamleader' or public.is_responsible_any(p_case_id)) then
    raise exception 'AAA_FLOW_AUTH: nur Zuständiger, Teamleader oder Admin' using errcode = '42501';
  end if;
  if not public.can_view_case(p_case_id) then
    raise exception 'AAA_FLOW_AUTH: Vorgang nicht sichtbar' using errcode = '42501';
  end if;
  perform public.enable_internal_write();
  perform set_config('app.audit_reason', p_reason, true);
  update public.cases set status = 'discarded', closed_reason = p_reason
   where id = p_case_id and status not in ('completed', 'discarded');
  if not found then
    raise exception 'AAA_FLOW_STATE: Vorgang ist bereits abgeschlossen oder verworfen' using errcode = 'P0001';
  end if;
  perform set_config('app.audit_reason', '', true);
  perform public.disable_internal_write();
end $$;

-- -----------------------------------------------------------------------------
-- Ausnahmen (Spec 12)
-- -----------------------------------------------------------------------------
create or replace function public.request_exception(p_case_id uuid, p_checkpoint_id uuid, p_reason text)
returns public.exceptions
language plpgsql security definer set search_path = public as $$
declare
  v_me public.users := public.me();
  v_cp public.checkpoints;
  v_ex public.exceptions;
begin
  if v_me.id is null then raise exception 'AAA_FLOW_AUTH: kein aktiver Nutzer' using errcode = '42501'; end if;
  select * into v_cp from public.checkpoints where id = p_checkpoint_id;
  if v_cp.id is null then raise exception 'AAA_FLOW_STATE: Prüfpunkt unbekannt' using errcode = 'P0001'; end if;
  if not (public.is_admin() or public.is_teamleader_of(v_cp.department) or public.is_responsible(p_case_id, v_cp.department)) then
    raise exception 'AAA_FLOW_AUTH: Ausnahme beantragt nur der Zuständige, Teamleader oder Admin' using errcode = '42501';
  end if;
  if public.checkpoint_is_done(p_case_id, p_checkpoint_id) then
    raise exception 'AAA_FLOW_STATE: Prüfpunkt ist bereits erledigt oder freigestellt' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.exceptions where case_id = p_case_id and checkpoint_id = p_checkpoint_id and status = 'requested') then
    raise exception 'AAA_FLOW_STATE: Für diesen Prüfpunkt liegt bereits ein offener Antrag vor' using errcode = 'P0001';
  end if;
  perform public.enable_internal_write();
  insert into public.exceptions (case_id, gate_no, checkpoint_id, reason, requested_by)
  values (p_case_id, v_cp.gate_no, p_checkpoint_id, p_reason, v_me.id)
  returning * into v_ex;
  perform public.notify(public.function_holder('director_training'), p_case_id, 'exception_requested', jsonb_build_object('exception_id', v_ex.id));
  perform public.notify(public.function_holder('head_of_training'), p_case_id, 'exception_requested', jsonb_build_object('exception_id', v_ex.id));
  perform public.disable_internal_write();
  return v_ex;
end $$;

create or replace function public.decide_exception(p_exception_id uuid, p_approve boolean, p_note text default null)
returns public.exceptions
language plpgsql security definer set search_path = public as $$
declare
  v_me public.users := public.me();
  v_ex public.exceptions;
begin
  if not public.can_decide_exceptions() then
    raise exception 'AAA_FLOW_AUTH: Ausnahmen gibt nur Director Training oder Head of Training frei' using errcode = '42501';
  end if;
  select * into v_ex from public.exceptions where id = p_exception_id for update;
  if v_ex.id is null then raise exception 'AAA_FLOW_STATE: Antrag unbekannt' using errcode = 'P0001'; end if;
  if v_ex.status <> 'requested' then
    raise exception 'AAA_FLOW_STATE: Antrag ist bereits entschieden' using errcode = 'P0001';
  end if;
  perform public.enable_internal_write();
  update public.exceptions
     set status = case when p_approve then 'approved'::public.exception_state else 'rejected'::public.exception_state end,
         decided_by = v_me.id, decided_at = now(), decision_note = p_note
   where id = p_exception_id
   returning * into v_ex;
  perform public.notify(v_ex.requested_by, v_ex.case_id, 'exception_decided',
    jsonb_build_object('exception_id', v_ex.id, 'status', v_ex.status));
  perform public.disable_internal_write();
  return v_ex;
end $$;

-- -----------------------------------------------------------------------------
-- Übernahmefunktion (Spec 5): kursweite Felder auf Vorgänge mit gleichem Muster
-- und Kursdatum kopieren. Reine Eingabehilfe, keine Verknüpfung.
-- -----------------------------------------------------------------------------
create or replace function public.copy_course_fields(p_source_case_id uuid)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_src public.cases;
  v_count integer;
begin
  select * into v_src from public.cases where id = p_source_case_id;
  if v_src.id is null then raise exception 'AAA_FLOW_STATE: Vorgang unbekannt' using errcode = 'P0001'; end if;
  if v_src.course_start is null then
    raise exception 'AAA_FLOW_STATE: Quellvorgang hat kein Kursdatum' using errcode = 'P0001';
  end if;
  if not (public.is_admin() or public.my_department() in ('training_admin', 'ato')) then
    raise exception 'AAA_FLOW_AUTH: Übernahme nur durch Training Admin, ATO oder Admin' using errcode = '42501';
  end if;
  perform public.enable_internal_write();
  update public.cases c
     set instructor = v_src.instructor,
         examiner   = v_src.examiner,
         fstd_slot  = v_src.fstd_slot,
         course_end = v_src.course_end
   where c.id <> v_src.id
     and c.aircraft_type_id = v_src.aircraft_type_id
     and c.course_start = v_src.course_start
     and c.status not in ('completed', 'discarded');
  get diagnostics v_count = row_count;
  perform public.disable_internal_write();
  return v_count;
end $$;

-- -----------------------------------------------------------------------------
-- Erinnerungen und Eskalation (Spec 11), täglich per Cron
--   settings.reminders:   {"days_before": [3, 1]}
--   settings.escalation:  {"contacts": {"sales": uuid, "training_admin": uuid, "ato": uuid},
--                          "level2_after_business_days": 2}
-- -----------------------------------------------------------------------------
create or replace function public.generate_reminders()
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_days integer[] := coalesce((select array(select jsonb_array_elements_text(value -> 'days_before'))::integer[]
                                from public.settings where key = 'reminders'), array[3, 1]);
  v_contacts jsonb := coalesce((select value -> 'contacts' from public.settings where key = 'escalation'), '{}'::jsonb);
  v_level2_days integer := coalesce((select (value ->> 'level2_after_business_days')::integer from public.settings where key = 'escalation'), 2);
  v_count integer := 0;
  r record;
  v_target uuid;
  v_days_left integer;
  v_escalated_at timestamptz;
begin
  perform public.enable_internal_write();
  for r in
    select cc.id as case_checkpoint_id, cc.case_id, cc.due_at, cp.id as checkpoint_id, cp.department, cp.label_de,
           ca.user_id as responsible
    from public.case_checkpoints cc
    join public.checkpoints cp on cp.id = cc.checkpoint_id
    join public.cases c on c.id = cc.case_id
    left join public.case_assignments ca on ca.case_id = cc.case_id and ca.department = cp.department
    where cc.status <> 'verified'
      and cc.due_at is not null
      and cp.mandatory
      and c.status in ('booked', 'released', 'in_progress')   -- Fristen laufen nur mit Kursdatum (Spec 6)
      and not exists (select 1 from public.exceptions e where e.case_id = cc.case_id and e.checkpoint_id = cp.id and e.status = 'approved')
  loop
    v_days_left := public.business_days_between(current_date, r.due_at);

    if r.due_at >= current_date and v_days_left = any (v_days) then
      -- Erinnerung an den Zuständigen (oder in den Pool: Teamleader)
      if not exists (select 1 from public.notifications n where n.type = 'reminder' and n.case_id = r.case_id
                       and n.payload ->> 'case_checkpoint_id' = r.case_checkpoint_id::text
                       and n.payload ->> 'days_left' = v_days_left::text) then
        if r.responsible is not null then
          perform public.notify(r.responsible, r.case_id, 'reminder',
            jsonb_build_object('case_checkpoint_id', r.case_checkpoint_id, 'days_left', v_days_left, 'label', r.label_de));
        else
          perform public.notify_department(r.department, r.case_id, 'reminder',
            jsonb_build_object('case_checkpoint_id', r.case_checkpoint_id, 'days_left', v_days_left, 'label', r.label_de), 'teamleader');
        end if;
        v_count := v_count + 1;
      end if;

    elsif r.due_at < current_date then
      -- Stufe 1: Eskalationsstufe der Abteilung
      select min(created_at) into v_escalated_at from public.notifications n
       where n.type = 'escalation' and n.case_id = r.case_id
         and n.payload ->> 'case_checkpoint_id' = r.case_checkpoint_id::text;
      if v_escalated_at is null then
        v_target := nullif(v_contacts ->> r.department::text, '')::uuid;
        if v_target is not null then
          perform public.notify(v_target, r.case_id, 'escalation',
            jsonb_build_object('case_checkpoint_id', r.case_checkpoint_id, 'label', r.label_de, 'department', r.department, 'due_at', r.due_at));
        else
          perform public.notify_department(r.department, r.case_id, 'escalation',
            jsonb_build_object('case_checkpoint_id', r.case_checkpoint_id, 'label', r.label_de, 'department', r.department, 'due_at', r.due_at), 'teamleader');
        end if;
        update public.notifications set escalated = true
         where type = 'reminder' and case_id = r.case_id and payload ->> 'case_checkpoint_id' = r.case_checkpoint_id::text;
        v_count := v_count + 1;
      -- Stufe 2: Dashboard Director Training und Head of Training
      elsif public.business_days_between(v_escalated_at::date, current_date) >= v_level2_days
            and not exists (select 1 from public.notifications n where n.type = 'escalation_level2' and n.case_id = r.case_id
                              and n.payload ->> 'case_checkpoint_id' = r.case_checkpoint_id::text) then
        perform public.notify(public.function_holder('director_training'), r.case_id, 'escalation_level2',
          jsonb_build_object('case_checkpoint_id', r.case_checkpoint_id, 'label', r.label_de, 'department', r.department, 'due_at', r.due_at));
        perform public.notify(public.function_holder('head_of_training'), r.case_id, 'escalation_level2',
          jsonb_build_object('case_checkpoint_id', r.case_checkpoint_id, 'label', r.label_de, 'department', r.department, 'due_at', r.due_at));
        v_count := v_count + 1;
      end if;
    end if;
  end loop;
  perform public.disable_internal_write();
  return v_count;
end $$;

-- Tagesjob: alle periodischen Regeln in einem Aufruf (für pg_cron oder Edge Function)
create or replace function public.run_daily_jobs()
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return jsonb_build_object(
    'advanced_in_progress', public.advance_in_progress(),
    'stale_pool',           public.escalate_stale_pool(),
    'reminders',            public.generate_reminders()
  );
end $$;

-- -----------------------------------------------------------------------------
-- Kommunikation (Spec 5a): nicht löschbar, Bearbeitung mit Historie, Erwähnungen
-- -----------------------------------------------------------------------------
create or replace function public.tg_messages_no_delete()
returns trigger
language plpgsql as $$
begin
  raise exception 'AAA_FLOW_IMMUTABLE: Nachrichten sind Teil der Vorgangsakte und können nicht gelöscht werden'
    using errcode = 'P0001';
end $$;
create trigger messages_no_delete before delete on public.messages
  for each row execute function public.tg_messages_no_delete();

create or replace function public.tg_messages_before_insert()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.user_id is null then new.user_id := auth.uid(); end if;
  if not public.can_view_thread(new.scope, new.scope_id) then
    raise exception 'AAA_FLOW_AUTH: Thread nicht sichtbar' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger messages_before_insert before insert on public.messages
  for each row execute function public.tg_messages_before_insert();

create or replace function public.tg_messages_before_update()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.scope <> old.scope or new.scope_id <> old.scope_id or new.user_id <> old.user_id
     or new.created_at <> old.created_at then
    raise exception 'AAA_FLOW_IMMUTABLE: Kontext, Autor und Zeitstempel einer Nachricht sind unveränderlich' using errcode = 'P0001';
  end if;
  if old.user_id <> auth.uid() and not public.is_superadmin() then
    raise exception 'AAA_FLOW_AUTH: nur der Autor darf eine Nachricht bearbeiten' using errcode = '42501';
  end if;
  if new.body is distinct from old.body then
    insert into public.message_edits (message_id, previous_body, edited_by)
    values (old.id, old.body, auth.uid());
    new.edited_at := now();
  end if;
  return new;
end $$;
create trigger messages_before_update before update on public.messages
  for each row execute function public.tg_messages_before_update();

-- Erwähnung → Benachrichtigung (Person oder ganze Abteilung)
create or replace function public.tg_mentions_notify()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_msg public.messages;
  v_case_id uuid;
begin
  select * into v_msg from public.messages where id = new.message_id;
  v_case_id := case when v_msg.scope = 'case' then v_msg.scope_id end;
  if new.user_id is not null then
    perform public.notify(new.user_id, v_case_id, 'mention',
      jsonb_build_object('message_id', v_msg.id, 'scope', v_msg.scope, 'scope_id', v_msg.scope_id));
  else
    perform public.notify_department(new.department, v_case_id, 'mention',
      jsonb_build_object('message_id', v_msg.id, 'scope', v_msg.scope, 'scope_id', v_msg.scope_id));
  end if;
  return null;
end $$;
create trigger mentions_notify after insert on public.message_mentions
  for each row execute function public.tg_mentions_notify();

-- Nachricht mit Erwähnungen in einem Aufruf (empfohlener Pfad für Clients).
-- Ein direkter INSERT in messages ist per RLS ebenfalls möglich; Erwähnungen
-- müssen dann in einem zweiten Statement folgen.
create or replace function public.post_message(
  p_scope public.message_scope,
  p_scope_id uuid,
  p_body text,
  p_checkpoint_id uuid default null,
  p_mention_user_ids uuid[] default '{}',
  p_mention_departments public.department[] default '{}'
) returns public.messages
language plpgsql security definer set search_path = public as $$
declare
  v_me public.users := public.me();
  v_msg public.messages;
begin
  if v_me.id is null then raise exception 'AAA_FLOW_AUTH: kein aktiver Nutzer' using errcode = '42501'; end if;
  if not public.can_view_thread(p_scope, p_scope_id) then
    raise exception 'AAA_FLOW_AUTH: Thread nicht sichtbar' using errcode = '42501';
  end if;
  insert into public.messages (scope, scope_id, user_id, body, checkpoint_id)
  values (p_scope, p_scope_id, v_me.id, p_body, p_checkpoint_id)
  returning * into v_msg;
  insert into public.message_mentions (message_id, user_id)
  select v_msg.id, u.id from public.users u
  where u.id = any (coalesce(p_mention_user_ids, '{}')) and u.active;
  insert into public.message_mentions (message_id, department)
  select v_msg.id, d from unnest(coalesce(p_mention_departments, '{}'::public.department[])) d;
  return v_msg;
end $$;

-- Lesestand setzen
create or replace function public.mark_thread_read(p_scope public.message_scope, p_scope_id uuid)
returns void
language sql security definer set search_path = public as $$
  insert into public.thread_reads (user_id, scope, scope_id, last_read_at)
  values (auth.uid(), p_scope, p_scope_id, now())
  on conflict (user_id, scope, scope_id) do update set last_read_at = excluded.last_read_at;
$$;

-- Nutzer dürfen an eigenen Benachrichtigungen nur read_at setzen
create or replace function public.tg_notifications_guard()
returns trigger
language plpgsql as $$
begin
  if public.internal_write_enabled() or public.is_admin() then return new; end if;
  if to_jsonb(new) - 'read_at' <> to_jsonb(old) - 'read_at' then
    raise exception 'AAA_FLOW_GUARD: Benachrichtigungen können nur als gelesen markiert werden' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger notifications_guard before update on public.notifications
  for each row execute function public.tg_notifications_guard();

-- Benachrichtigung als gelesen markieren
create or replace function public.mark_notifications_read(p_ids uuid[])
returns integer
language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  update public.notifications set read_at = now()
   where id = any (p_ids) and user_id = auth.uid() and read_at is null;
  get diagnostics v_count = row_count;
  perform public.disable_internal_write();
  return v_count;
end $$;
