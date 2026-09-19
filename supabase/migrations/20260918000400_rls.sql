-- =============================================================================
-- Project Control Center — Migration 4/6: Row Level Security
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
      pcc.milestones, pcc.risks, pcc.issues, pcc.decisions, pcc.raci to authenticated;
-- Dokumente und Kommentare verschwinden nie hart: pcc.delete_document() und
-- pcc.delete_comment() setzen den Löschvermerk. Ein Delete-Recht gäbe es hier
-- also nur zum Schein — die Policies lassen es ohnehin nicht zu.
grant insert, update on pcc.documents, pcc.comments to authenticated;
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
                           'project_versions','version_changes','ref_counters','settings',
                           'changelog']
  loop
    execute format('alter table pcc.%I enable row level security', t);
    execute format('alter table pcc.%I force row level security', t);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Personenverzeichnis und Audit-Trail
-- Beide Zugänge lesen das Verzeichnis — ohne das ließe sich keine
-- Zuständigkeit anzeigen. Pflegen darf es der Teamzugang; Rolle und Verbindung
-- zum Anmeldekonto hält der Guard aus Migration 3 in jedem Fall fest.
-- -----------------------------------------------------------------------------
alter table public.users enable row level security;
alter table public.users force row level security;
alter table public.audit_log enable row level security;
alter table public.audit_log force row level security;
revoke all on public.users, public.audit_log from anon;
grant select on public.users, public.audit_log to authenticated;
grant insert, update on public.users to authenticated;

create policy users_select on public.users for select to authenticated
  using (pcc.is_user());
create policy users_insert on public.users for insert to authenticated
  with check (pcc.is_team());
create policy users_update on public.users for update to authenticated
  using (pcc.is_team()) with check (pcc.is_team());
-- Kein Delete: eine Person wird stillgelegt oder pseudonymisiert, nie
-- gelöscht — sonst verlören Aufgaben und Trail ihren Bezug (Abschnitt 7b).

-- Der Trail ist für beide Zugänge lesbar. Bei gemeinsam benutzten Zugängen
-- wäre eine feinere Abstufung ohnehin nur Zierde.
create policy audit_log_select on public.audit_log for select to authenticated
  using (pcc.is_user());

create trigger audit_log_immutable before update or delete on public.audit_log
  for each row execute function pcc.tg_audit_immutable();
comment on table public.audit_log is 'Vollständiger Audit-Trail. Kein Weg in der Anwendung ändert oder löscht einen Eintrag.';

-- -----------------------------------------------------------------------------
-- Fachdaten
-- Entschieden am 19.09.2026: es gibt zwei Zugänge. Gelesen wird von beiden,
-- geschrieben nur vom Teamzugang — und auch von ihm nicht in einem
-- archivierten Projekt (das prüft pcc.can_edit). Damit fällt die gesamte
-- Abstufung nach Projektmitgliedschaft und Zuweisung weg: sie beschrieb
-- Rechte, die es nicht mehr gibt.
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['projects','project_members','workstreams','tasks','milestones',
                           'risks','issues','decisions','raci']
  loop
    -- Projekte tragen die Kennung in id, alles Übrige in project_id.
    execute format(
      'create policy %1$I_select on pcc.%1$I for select to authenticated using (pcc.can_read(%2$s))',
      t, case when t = 'projects' then 'id' else 'project_id' end);
    if t <> 'projects' then
      -- Projekte entstehen ausschließlich über pcc.create_project(): dort
      -- werden Projektleitung, Mitgliedschaft und Version 1.0 in einem Zug
      -- erzeugt. Deshalb dort kein Insert und kein Delete.
      execute format(
        'create policy %1$I_write on pcc.%1$I for all to authenticated
           using (pcc.can_edit(project_id)) with check (pcc.can_edit(project_id))', t);
    else
      execute format(
        'create policy %1$I_update on pcc.%1$I for update to authenticated
           using (pcc.can_edit(id)) with check (pcc.can_edit(id))', t);
    end if;
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Dokumente. Gelöschtes bleibt für den Teamzugang sichtbar, für den
-- Lesezugang nicht. Endgültiges Entfernen läuft über eine Funktion mit
-- Eintrag im Trail.
-- -----------------------------------------------------------------------------
create policy documents_select on pcc.documents for select to authenticated
  using (pcc.can_read(project_id) and (deleted_at is null or pcc.is_team()));
create policy documents_insert on pcc.documents for insert to authenticated
  with check (pcc.can_contribute(project_id));
create policy documents_update on pcc.documents for update to authenticated
  using (pcc.can_edit(project_id)) with check (pcc.can_edit(project_id));

-- -----------------------------------------------------------------------------
-- Kommentare. Bei einem gemeinsamen Zugang lässt sich „mein Kommentar" nicht
-- mehr durchsetzen — wer den Zugang hat, hat ihn für alle Kommentare. Die
-- Zuschreibung bleibt sichtbar, verbindlich ist sie nicht.
-- -----------------------------------------------------------------------------
create policy comments_select on pcc.comments for select to authenticated
  using (pcc.can_read(project_id));
create policy comments_insert on pcc.comments for insert to authenticated
  with check (pcc.can_contribute(project_id));
create policy comments_update on pcc.comments for update to authenticated
  using (pcc.can_edit(project_id) and deleted_at is null)
  with check (pcc.can_edit(project_id));

create policy mentions_select on pcc.mentions for select to authenticated
  using (exists (select 1 from pcc.comments c where c.id = comment_id and pcc.can_read(c.project_id)));

-- Benachrichtigungen sind an Personen gerichtet, nicht an Zugänge. Beide
-- Zugänge sehen sie; als gelesen markieren darf sie der Teamzugang.
create policy notifications_select on pcc.notifications for select to authenticated
  using (pcc.is_user());
create policy notifications_update on pcc.notifications for update to authenticated
  using (pcc.is_team()) with check (pcc.is_team());

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
  using (pcc.is_team()) with check (pcc.is_team());

create policy changelog_select on pcc.changelog for select to authenticated
  using (pcc.is_user());

create policy settings_select on pcc.settings for select to authenticated
  using (pcc.is_user());
create policy settings_update on pcc.settings for update to authenticated
  using (pcc.is_team()) with check (pcc.is_team());

-- ref_counters und mentions bekommen bewusst keine Schreib-Policy: beide werden
-- ausschließlich von SECURITY-DEFINER-Funktionen gepflegt.

-- -----------------------------------------------------------------------------
-- Ausführungsrechte auf die gemeinsamen Hilfsfunktionen
-- Der interne Schreibmodus hebelt sämtliche Guards aus. Er gehört den
-- Funktionen dieses Schemas, nicht der API.
-- -----------------------------------------------------------------------------
revoke execute on function public.enable_internal_write() from public, anon, authenticated;
revoke execute on function public.disable_internal_write() from public, anon, authenticated;
-- Der Lesezugriff bleibt: die Guard-Trigger laufen im Recht des Aufrufers und
-- müssen den Schalter abfragen können. Umlegen kann ihn nur noch, wer als
-- Eigentümer der geprüften Funktionen läuft.

-- -----------------------------------------------------------------------------
-- Ausführungsrechte
-- -----------------------------------------------------------------------------
revoke all on all functions in schema pcc from public, anon;
grant execute on all functions in schema pcc to authenticated;
-- Der Tageslauf läuft über pg_cron als service_role, nicht aus der Oberfläche.
revoke execute on function pcc.run_daily_jobs() from authenticated;
-- Der Bootstrap gehört nicht an die API: er läuft einmal, mit direktem
-- Datenbankzugang, bei der Inbetriebnahme.
revoke execute on function pcc.prepare_account(text, pcc.user_role, text) from authenticated, anon, public;
revoke execute on function pcc.notify(uuid, uuid, pcc.notification_kind, pcc.entity_type, uuid, text, text) from authenticated;
revoke execute on function pcc.new_version(uuid, text, text, jsonb) from authenticated;
-- Referenznummern vergibt der Trigger. Von außen aufgerufen erzeugte sie nur
-- Lücken in der Zählung fremder Projekte.
revoke execute on function pcc.next_ref(uuid, text) from authenticated, anon, public;
-- Den Prüfstand eines Dokuments meldet die Virenprüfung, nicht die Oberfläche.
revoke execute on function pcc.set_scan_state(uuid, pcc.scan_state) from authenticated, anon, public;
grant execute on function pcc.set_scan_state(uuid, pcc.scan_state) to service_role;
grant execute on function pcc.run_daily_jobs() to service_role;
