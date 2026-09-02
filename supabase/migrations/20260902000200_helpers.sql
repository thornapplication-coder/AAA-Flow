-- =============================================================================
-- AAA Flow — Migration 2/5: Hilfsfunktionen
-- Arbeitstage, Identität, Rollen, Vertretung, Sichtbarkeit, Zuständigkeit
-- Alle Sichtbarkeitsfunktionen sind SECURITY DEFINER, damit RLS-Policies sie
-- ohne Rekursion nutzen können.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Arbeitstage (Mo–Fr). Feiertage sind bewusst nicht berücksichtigt (siehe
-- docs/ARCHITECTURE.md, Annahmen).
-- -----------------------------------------------------------------------------
create or replace function public.add_business_days(p_date date, p_days integer)
returns date
language plpgsql immutable as $$
declare
  d    date := p_date;
  step integer := sign(p_days);
  left_ integer := abs(p_days);
begin
  if p_date is null then return null; end if;
  while left_ > 0 loop
    d := d + step;
    if extract(isodow from d) < 6 then
      left_ := left_ - 1;
    end if;
  end loop;
  return d;
end $$;

create or replace function public.business_days_between(p_from date, p_to date)
returns integer
language sql immutable as $$
  select coalesce((
    select count(*)::integer
    from generate_series(p_from + 1, p_to, interval '1 day') g
    where extract(isodow from g) < 6
  ), 0);
$$;

-- -----------------------------------------------------------------------------
-- Identität und Rollen
-- -----------------------------------------------------------------------------
create or replace function public.current_user_id()
returns uuid
language sql stable as $$
  select auth.uid();
$$;

create or replace function public.me()
returns public.users
language sql stable security definer set search_path = public as $$
  select u.* from public.users u where u.id = auth.uid() and u.active;
$$;

create or replace function public.is_active_user()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.users where id = auth.uid() and active);
$$;

create or replace function public.my_role()
returns public.user_role
language sql stable security definer set search_path = public as $$
  select role from public.users where id = auth.uid() and active;
$$;

create or replace function public.my_department()
returns public.department
language sql stable security definer set search_path = public as $$
  select department from public.users where id = auth.uid() and active;
$$;

create or replace function public.is_superadmin()
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() = 'superadmin', false);
$$;

create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() in ('superadmin', 'admin'), false);
$$;

create or replace function public.is_teamleader_of(p_department public.department)
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() = 'teamleader' and public.my_department() = p_department, false);
$$;

-- -----------------------------------------------------------------------------
-- Vertretung: Nutzer, für die der aktuelle Nutzer heute handelt (inkl. sich selbst)
-- -----------------------------------------------------------------------------
create or replace function public.acting_as_user_ids()
returns setof uuid
language sql stable security definer set search_path = public as $$
  select auth.uid()
  union
  select d.user_id
  from public.deputies d
  where d.deputy_user_id = auth.uid()
    and current_date between d.valid_from and d.valid_to;
$$;

create or replace function public.is_acting_for(p_user_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select p_user_id is not null and p_user_id in (select public.acting_as_user_ids());
$$;

-- -----------------------------------------------------------------------------
-- Funktionsträger aus settings.function_holders
-- {"director_training": "<uuid>", "head_of_training": "<uuid>", "sales_lead": "<uuid>"}
-- -----------------------------------------------------------------------------
create or replace function public.function_holder(p_function text)
returns uuid
language sql stable security definer set search_path = public as $$
  select nullif(value ->> p_function, '')::uuid
  from public.settings
  where key = 'function_holders';
$$;

create or replace function public.is_function_holder(p_function text)
returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_acting_for(public.function_holder(p_function));
$$;

-- Ausnahmen darf nur Director Training oder Head of Training freigeben (Spec 12).
create or replace function public.can_decide_exceptions()
returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_superadmin()
      or public.is_function_holder('director_training')
      or public.is_function_holder('head_of_training');
$$;

-- -----------------------------------------------------------------------------
-- Musterzuordnung: eigene plus die der vertretenen Personen
-- -----------------------------------------------------------------------------
create or replace function public.my_aircraft_type_ids()
returns setof uuid
language sql stable security definer set search_path = public as $$
  select distinct ta.aircraft_type_id
  from public.type_assignments ta
  where ta.user_id in (select public.acting_as_user_ids());
$$;

-- -----------------------------------------------------------------------------
-- Zuständigkeit je Vorgang und Abteilung (inkl. Vertretung)
-- -----------------------------------------------------------------------------
create or replace function public.is_responsible(p_case_id uuid, p_department public.department)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.case_assignments ca
    where ca.case_id = p_case_id
      and ca.department = p_department
      and ca.user_id in (select public.acting_as_user_ids())
  );
$$;

create or replace function public.is_responsible_any(p_case_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.case_assignments ca
    where ca.case_id = p_case_id
      and ca.user_id in (select public.acting_as_user_ids())
  );
$$;

-- -----------------------------------------------------------------------------
-- Sichtbarkeit von Vorgängen (Spec Abschnitt 9)
--   Sales: nur Vorgänge der zugeordneten Muster (Pool wie eigene Liste);
--          Sales-Teamleitung und Sales-Leitung sehen alle Vorgänge.
--   Training Admin, ATO, Admins: alle Vorgänge.
--   Vertretung: zusätzlich alles, was der Vertretene sieht.
-- -----------------------------------------------------------------------------
create or replace function public.can_view_case(p_case_id uuid)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  v_me public.users;
begin
  select * into v_me from public.users where id = auth.uid() and active;
  if v_me.id is null then
    return false;
  end if;
  if v_me.role in ('superadmin', 'admin') then
    return true;
  end if;
  if v_me.department in ('training_admin', 'ato') then
    return true;
  end if;
  -- Sales
  if v_me.role = 'teamleader' or public.is_function_holder('sales_lead') then
    return true;
  end if;
  if public.is_responsible_any(p_case_id) then
    return true;
  end if;
  -- Vertretung einer Person aus einer anderen Abteilung, die alles sieht
  if exists (
    select 1 from public.users u
    where u.id in (select public.acting_as_user_ids())
      and u.id <> auth.uid()
      and (u.department in ('training_admin', 'ato') or u.role in ('superadmin', 'admin', 'teamleader'))
  ) then
    return true;
  end if;
  return exists (
    select 1 from public.cases c
    where c.id = p_case_id
      and c.aircraft_type_id in (select public.my_aircraft_type_ids())
  );
end $$;

create or replace function public.can_view_company(p_company_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin()
      or public.my_role() = 'teamleader'
      or exists (
        select 1 from public.cases c
        where c.company_id = p_company_id and public.can_view_case(c.id)
      );
$$;

create or replace function public.can_view_trainee(p_trainee_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin()
      or public.my_role() = 'teamleader'
      or exists (
        select 1 from public.cases c
        where c.trainee_id = p_trainee_id and public.can_view_case(c.id)
      );
$$;

-- Thread-Sichtbarkeit (Spec 5a): Vorgangs-/Trainee-Threads folgen dem Vorgang,
-- Firmen-Threads sieht jeder, der mindestens einen Vorgang der Firma sieht,
-- plus alle Teamleitungen.
create or replace function public.can_view_thread(p_scope public.message_scope, p_scope_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select case p_scope
    when 'case'    then public.can_view_case(p_scope_id)
    when 'trainee' then public.can_view_trainee(p_scope_id)
    when 'company' then public.can_view_company(p_scope_id)
  end;
$$;

-- Freigebende Abteilung je Gate (Spec Abschnitt 7)
create or replace function public.gate_release_department(p_gate_no integer)
returns public.department
language sql immutable as $$
  select case p_gate_no
    when 1 then 'training_admin'::public.department
    when 2 then 'ato'::public.department
    when 3 then 'training_admin'::public.department
  end;
$$;

-- Interner Bypass für Guard-Trigger: nur Geschäftslogik-Funktionen dürfen
-- Status, Gates und Prüfpunkte schreiben.
create or replace function public.internal_write_enabled()
returns boolean
language sql stable as $$
  select coalesce(current_setting('app.internal_write', true), '') = 'on';
$$;

create or replace function public.enable_internal_write()
returns void
language sql as $$
  select set_config('app.internal_write', 'on', true);
$$;

create or replace function public.disable_internal_write()
returns void
language sql as $$
  select set_config('app.internal_write', 'off', true);
$$;
