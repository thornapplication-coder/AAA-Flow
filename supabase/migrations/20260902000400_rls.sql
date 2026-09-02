-- =============================================================================
-- AAA Flow — Migration 4/5: Row Level Security und Grants
-- Sichtbarkeit (Spec 9), Threads (Spec 5a), Audit (Spec 13), Admin (Spec 14)
-- Kein anonymer Zugriff. Schreibende Kernoperationen laufen über Funktionen.
-- =============================================================================

-- Grants: nur authentifizierte Nutzer; anon bekommt nichts.
revoke all on schema public from anon;
revoke all on all tables in schema public from anon;
revoke all on all functions in schema public from anon;
grant usage on schema public to authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to authenticated, service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;
grant execute on all functions in schema public to authenticated, service_role;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on functions from anon;

-- Tagesjobs und Rohschreibfunktionen nur für den Service-Kontext
revoke execute on function public.run_daily_jobs() from authenticated;
revoke execute on function public.advance_in_progress() from authenticated;
revoke execute on function public.escalate_stale_pool() from authenticated;
revoke execute on function public.generate_reminders() from authenticated;
revoke execute on function public.audit_write(text, text, text, jsonb, jsonb, text, uuid) from authenticated;
revoke execute on function public.enable_internal_write() from authenticated;
revoke execute on function public.notify(uuid, uuid, public.notification_type, jsonb) from authenticated;
revoke execute on function public.notify_department(public.department, uuid, public.notification_type, jsonb, public.user_role) from authenticated;
revoke execute on function public.instantiate_case_checkpoints(uuid) from authenticated;
revoke execute on function public.recompute_due_dates(uuid) from authenticated;

-- RLS einschalten
do $$
declare t text;
begin
  foreach t in array array['users','aircraft_types','type_assignments','deputies','companies','trainees',
                           'checkpoints','cases','case_assignments','gates','case_checkpoints','exceptions',
                           'notifications','messages','message_edits','message_mentions','thread_reads',
                           'audit_log','settings','changelog']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- users
-- -----------------------------------------------------------------------------
create policy users_select on public.users for select to authenticated
  using (public.is_active_user());
create policy users_insert on public.users for insert to authenticated
  with check (public.is_superadmin());
create policy users_update on public.users for update to authenticated
  using (public.is_admin() or id = auth.uid())
  with check (public.is_admin() or id = auth.uid());
-- kein Delete: Nutzer werden deaktiviert (Audit-Trail bleibt referenzierbar)

-- -----------------------------------------------------------------------------
-- Stammdaten
-- -----------------------------------------------------------------------------
create policy aircraft_types_select on public.aircraft_types for select to authenticated using (public.is_active_user());
create policy aircraft_types_write on public.aircraft_types for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy type_assignments_select on public.type_assignments for select to authenticated using (public.is_active_user());
create policy type_assignments_write on public.type_assignments for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy deputies_select on public.deputies for select to authenticated using (public.is_active_user());
create policy deputies_write on public.deputies for all to authenticated
  using (public.is_admin() or public.my_role() = 'teamleader'
         or (user_id = auth.uid() and current_date <= valid_to))
  with check (public.is_admin() or public.my_role() = 'teamleader' or user_id = auth.uid());

create policy companies_select on public.companies for select to authenticated using (public.is_active_user());
create policy companies_insert on public.companies for insert to authenticated with check (public.is_active_user());
create policy companies_update on public.companies for update to authenticated
  using (public.is_admin() or public.my_role() = 'teamleader' or public.my_department() = 'sales')
  with check (public.is_admin() or public.my_role() = 'teamleader' or public.my_department() = 'sales');

create policy trainees_select on public.trainees for select to authenticated using (public.is_active_user());
create policy trainees_insert on public.trainees for insert to authenticated with check (public.is_active_user());
create policy trainees_update on public.trainees for update to authenticated
  using (public.is_active_user()) with check (public.is_active_user());

-- Prüfpunkt-Katalog: lesen alle, ändern nur Superadmin (Spec 4: Admin ohne Katalogänderung)
create policy checkpoints_select on public.checkpoints for select to authenticated using (public.is_active_user());
create policy checkpoints_write on public.checkpoints for all to authenticated
  using (public.is_superadmin()) with check (public.is_superadmin());

create policy settings_select on public.settings for select to authenticated using (public.is_active_user());
create policy settings_write on public.settings for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy changelog_select on public.changelog for select to authenticated using (public.is_active_user());
create policy changelog_write on public.changelog for all to authenticated
  using (public.is_superadmin()) with check (public.is_superadmin());

-- -----------------------------------------------------------------------------
-- Vorgang und Unterobjekte
-- -----------------------------------------------------------------------------
create policy cases_select on public.cases for select to authenticated
  using (public.can_view_case(id));
-- Anlage: Sales (Kundenanfrage), Training Admin, Teamleader, Admin
create policy cases_insert on public.cases for insert to authenticated
  with check (public.is_active_user()
              and (public.my_department() in ('sales', 'training_admin') or public.my_role() in ('superadmin', 'admin', 'teamleader'))
              and (public.my_department() <> 'sales' or public.my_role() <> 'staff' or public.is_function_holder('sales_lead')
                   or aircraft_type_id in (select public.my_aircraft_type_ids())));
-- Bearbeitung der Stammfelder: Zuständige (jede Abteilung), Teamleader, Admin.
-- Status/closed_reason schützt tg_cases_guard.
create policy cases_update on public.cases for update to authenticated
  using (public.can_view_case(id) and (public.is_admin() or public.my_role() = 'teamleader' or public.is_responsible_any(id)))
  with check (public.can_view_case(id));
-- kein Delete: Vorgänge werden verworfen (discard_case)

create policy case_assignments_select on public.case_assignments for select to authenticated
  using (public.can_view_case(case_id));
create policy gates_select on public.gates for select to authenticated
  using (public.can_view_case(case_id));
create policy case_checkpoints_select on public.case_checkpoints for select to authenticated
  using (public.can_view_case(case_id));
create policy exceptions_select on public.exceptions for select to authenticated
  using (public.can_view_case(case_id));
-- Schreiben ausschließlich über Funktionen (tg_internal_only); keine Insert/Update/Delete-Policies.

-- -----------------------------------------------------------------------------
-- Benachrichtigungen: nur eigene; Admins sehen fehlgeschlagene Mails (Spec 14)
-- -----------------------------------------------------------------------------
create policy notifications_select on public.notifications for select to authenticated
  using (user_id = auth.uid() or (public.is_admin() and email_status = 'failed'));
create policy notifications_update on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- Kommunikation
-- -----------------------------------------------------------------------------
create policy messages_select on public.messages for select to authenticated
  using (public.can_view_thread(scope, scope_id));
create policy messages_insert on public.messages for insert to authenticated
  with check (public.is_active_user() and user_id = auth.uid() and public.can_view_thread(scope, scope_id));
create policy messages_update on public.messages for update to authenticated
  using (user_id = auth.uid() or public.is_superadmin())
  with check (user_id = auth.uid() or public.is_superadmin());
-- kein Delete (zusätzlich Trigger messages_no_delete)

create policy message_edits_select on public.message_edits for select to authenticated
  using (exists (select 1 from public.messages m where m.id = message_id and public.can_view_thread(m.scope, m.scope_id)));

create policy message_mentions_select on public.message_mentions for select to authenticated
  using (exists (select 1 from public.messages m where m.id = message_id and public.can_view_thread(m.scope, m.scope_id)));
create policy message_mentions_insert on public.message_mentions for insert to authenticated
  with check (exists (select 1 from public.messages m where m.id = message_id and m.user_id = auth.uid()));

create policy thread_reads_all on public.thread_reads for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- Audit-Trail: Admins alles; sonst nur Einträge zu sichtbaren Vorgängen.
-- Keine Insert/Update/Delete-Policies: schreibt nur der Trigger (definer).
-- -----------------------------------------------------------------------------
create policy audit_log_select on public.audit_log for select to authenticated
  using (public.is_admin() or (case_id is not null and public.can_view_case(case_id)));
