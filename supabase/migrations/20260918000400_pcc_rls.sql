-- =============================================================================
-- Project Control Center — Migration 4/5: Row Level Security
-- Abschnitt 43: Kein einziger Rechtecheck verlässt sich auf das Frontend.
-- Wer keine Rolle im Control Center hat, sieht nichts — auch nicht mit
-- gültigem Token und direktem API-Zugriff.
-- =============================================================================

grant usage on schema pcc to authenticated, service_role;
revoke all on schema pcc from anon;

-- Lesen darf die Rolle authenticated auf allen Tabellen; was sie tatsächlich
-- sieht, entscheidet die Policy.
grant select on all tables in schema pcc to authenticated;
grant insert, update, delete on pcc.project_members, pcc.workstreams, pcc.tasks,
      pcc.milestones, pcc.risks, pcc.issues, pcc.decisions, pcc.raci,
      pcc.documents, pcc.comments to authenticated;
grant update on pcc.projects, pcc.notifications to authenticated;
grant insert, update, delete on pcc.templates to authenticated;
grant update on pcc.settings to authenticated;
revoke all on all tables in schema pcc from anon;
grant usage on all sequences in schema pcc to authenticated;

do $$
declare t text;
begin
  foreach t in array array['templates','projects','project_members','workstreams','tasks',
                           'milestones','risks','issues','decisions','raci','documents',
                           'comments','mentions','notifications','version_triggers',
                           'project_versions','version_changes','ref_counters','settings']
  loop
    execute format('alter table pcc.%I enable row level security', t);
    execute format('alter table pcc.%I force row level security', t);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Gemeinsame Tabellen: Zugang aus dem Control Center heraus
-- Die Flow-Policies bleiben unverändert; hier kommen eigene hinzu. Policies
-- sind additiv, ein Flow-Nutzer verliert dadurch nichts.
-- -----------------------------------------------------------------------------
create policy users_select_pcc on public.users for select to authenticated
  using (pcc.is_user());

create policy audit_log_select_pcc on public.audit_log for select to authenticated
  using (module = 'pcc' and (pcc.is_admin()
      or (project_id is not null and pcc.can_read(project_id))));

-- -----------------------------------------------------------------------------
-- Projekte
-- Abschnitt 4, entschieden am 18.09.2026: jeder freigegebene Nutzer liest alle
-- nicht archivierten Projekte. Geändert wird nur nach Rolle.
-- -----------------------------------------------------------------------------
create policy projects_select on pcc.projects for select to authenticated
  using (pcc.can_read(id));
-- Anlegen ausschließlich über pcc.create_project(): dort werden Projektleitung,
-- Mitgliedschaft und Version 1.0 in einem Zug erzeugt.
create policy projects_update on pcc.projects for update to authenticated
  using (pcc.can_edit(id)) with check (pcc.can_edit(id));

create policy members_select on pcc.project_members for select to authenticated
  using (pcc.can_read(project_id));
create policy members_write on pcc.project_members for all to authenticated
  using (pcc.can_edit(project_id)) with check (pcc.can_edit(project_id));

create policy workstreams_select on pcc.workstreams for select to authenticated
  using (pcc.can_read(project_id));
create policy workstreams_write on pcc.workstreams for all to authenticated
  using (pcc.can_edit(project_id)) with check (pcc.can_edit(project_id));

-- -----------------------------------------------------------------------------
-- Aufgaben: der Contributor bearbeitet, was ihm zugewiesen ist — nicht mehr.
-- -----------------------------------------------------------------------------
create policy tasks_select on pcc.tasks for select to authenticated
  using (pcc.can_read(project_id));
create policy tasks_insert on pcc.tasks for insert to authenticated
  with check (pcc.can_edit(project_id));
create policy tasks_update on pcc.tasks for update to authenticated
  using (pcc.can_edit(project_id)
      or (pcc.can_contribute(project_id) and assignee_user_id = auth.uid()))
  with check (pcc.can_edit(project_id)
      or (pcc.can_contribute(project_id) and assignee_user_id = auth.uid()));
create policy tasks_delete on pcc.tasks for delete to authenticated
  using (pcc.can_edit(project_id));

create policy milestones_select on pcc.milestones for select to authenticated
  using (pcc.can_read(project_id));
create policy milestones_write on pcc.milestones for all to authenticated
  using (pcc.can_edit(project_id)) with check (pcc.can_edit(project_id));

create policy risks_select on pcc.risks for select to authenticated
  using (pcc.can_read(project_id));
create policy risks_insert on pcc.risks for insert to authenticated
  with check (pcc.can_contribute(project_id));
create policy risks_update on pcc.risks for update to authenticated
  using (pcc.can_edit(project_id)
      or (pcc.can_contribute(project_id) and owner_user_id = auth.uid()))
  with check (pcc.can_edit(project_id)
      or (pcc.can_contribute(project_id) and owner_user_id = auth.uid()));
create policy risks_delete on pcc.risks for delete to authenticated
  using (pcc.can_edit(project_id));

-- Issues darf jedes Projektmitglied melden (Abschnitt 5).
create policy issues_select on pcc.issues for select to authenticated
  using (pcc.can_read(project_id));
create policy issues_insert on pcc.issues for insert to authenticated
  with check (pcc.can_contribute(project_id));
create policy issues_update on pcc.issues for update to authenticated
  using (pcc.can_edit(project_id)
      or (pcc.can_contribute(project_id) and (owner_user_id = auth.uid() or created_by = auth.uid())))
  with check (pcc.can_edit(project_id)
      or (pcc.can_contribute(project_id) and (owner_user_id = auth.uid() or created_by = auth.uid())));
create policy issues_delete on pcc.issues for delete to authenticated
  using (pcc.can_edit(project_id));

create policy decisions_select on pcc.decisions for select to authenticated
  using (pcc.can_read(project_id));
create policy decisions_write on pcc.decisions for all to authenticated
  using (pcc.can_edit(project_id)) with check (pcc.can_edit(project_id));

create policy raci_select on pcc.raci for select to authenticated
  using (pcc.can_read(project_id));
create policy raci_write on pcc.raci for all to authenticated
  using (pcc.can_edit(project_id)) with check (pcc.can_edit(project_id));

-- -----------------------------------------------------------------------------
-- Dokumente. Gelöschtes bleibt für den Super Admin sichtbar, für alle anderen
-- nicht. Endgültiges Entfernen läuft über eine Funktion mit Audit-Eintrag.
-- -----------------------------------------------------------------------------
create policy documents_select on pcc.documents for select to authenticated
  using (pcc.can_read(project_id) and (deleted_at is null or pcc.is_super_admin()));
create policy documents_insert on pcc.documents for insert to authenticated
  with check (pcc.can_contribute(project_id));
create policy documents_update on pcc.documents for update to authenticated
  using (pcc.can_edit(project_id) or owner_user_id = auth.uid())
  with check (pcc.can_edit(project_id) or owner_user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- Kommentare: eigene bearbeiten, fremde nur lesen. Löschen über delete_comment().
-- -----------------------------------------------------------------------------
create policy comments_select on pcc.comments for select to authenticated
  using (pcc.can_read(project_id));
create policy comments_insert on pcc.comments for insert to authenticated
  with check (pcc.can_contribute(project_id) and user_id = auth.uid());
create policy comments_update on pcc.comments for update to authenticated
  using (user_id = auth.uid() and deleted_at is null)
  with check (user_id = auth.uid());

create policy mentions_select on pcc.mentions for select to authenticated
  using (exists (select 1 from pcc.comments c where c.id = comment_id and pcc.can_read(c.project_id)));

create policy notifications_select on pcc.notifications for select to authenticated
  using (user_id = auth.uid());
create policy notifications_update on pcc.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- Versionen sind unveränderlich und werden nur von Funktionen geschrieben.
-- -----------------------------------------------------------------------------
create policy versions_select on pcc.project_versions for select to authenticated
  using (pcc.can_read(project_id));
create policy version_changes_select on pcc.version_changes for select to authenticated
  using (exists (select 1 from pcc.project_versions v
                 where v.id = version_id and pcc.can_read(v.project_id)));
create policy version_triggers_select on pcc.version_triggers for select to authenticated
  using (pcc.is_user());

create policy templates_select on pcc.templates for select to authenticated
  using (pcc.is_user());
create policy templates_write on pcc.templates for all to authenticated
  using (pcc.is_admin()) with check (pcc.is_admin());

create policy settings_select on pcc.settings for select to authenticated
  using (pcc.is_user());
create policy settings_update on pcc.settings for update to authenticated
  using (pcc.is_super_admin()) with check (pcc.is_super_admin());

-- ref_counters und mentions bekommen bewusst keine Schreib-Policy: beide werden
-- ausschließlich von SECURITY-DEFINER-Funktionen gepflegt.

-- -----------------------------------------------------------------------------
-- Unveränderlichkeit
-- -----------------------------------------------------------------------------
-- Versionen sind unveränderlich. Einzige Ausnahme: das endgültige Löschen eines
-- Projekts durch den Super Admin, das über den internen Schreibmodus läuft und
-- selbst einen Eintrag im Audit-Trail hinterlässt.
create or replace function pcc.tg_immutable()
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
  for each row execute function pcc.tg_immutable();
create trigger version_changes_immutable before update or delete on pcc.version_changes
  for each row execute function pcc.tg_immutable();

-- -----------------------------------------------------------------------------
-- Ausführungsrechte
-- -----------------------------------------------------------------------------
revoke all on all functions in schema pcc from public, anon;
grant execute on all functions in schema pcc to authenticated;
-- Der Tageslauf läuft über pg_cron als service_role, nicht aus der Oberfläche.
revoke execute on function pcc.run_daily_jobs() from authenticated;
revoke execute on function pcc.notify(uuid, uuid, pcc.notification_kind, pcc.entity_type, uuid, text, text) from authenticated;
revoke execute on function pcc.new_version(uuid, text, text, jsonb) from authenticated;
grant execute on function pcc.run_daily_jobs() to service_role;
