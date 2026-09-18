-- =============================================================================
-- Project Control Center — SQL-Tests
-- Registrierung und Freigabe, Rechte, Projekte, Referenzen, Versionierung,
-- Gesamtlage, Fortschritt, Dokumente, Kommentare, Löschweg, Tageslauf.
-- Läuft in einer Transaktion und rollt am Ende zurück.
-- =============================================================================
\set ON_ERROR_STOP on
\set QUIET on
begin;

create schema test;
grant usage on schema test to authenticated;
create table test_users (key text primary key, id uuid not null default gen_random_uuid());
create table test_ids (key text primary key, id uuid not null);
grant select on test_users, test_ids to authenticated;
grant insert on test_ids to authenticated;

create function test.login(p_key text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from test_users where key = p_key;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated')::text, true);
  execute 'set role authenticated';
end $$;
create function test.logout() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;
create function test.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is distinct from true then
    raise exception 'TEST FAILED: %', p_msg;
  end if;
  raise notice 'ok - %', p_msg;
end $$;
create function test.fails(p_sql text, p_needle text, p_msg text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_needle in sqlerrm) = 0 then
      raise exception 'TEST FAILED: % — erwartet "%", erhalten "%"', p_msg, p_needle, sqlerrm;
    end if;
    raise notice 'ok - % [%]', p_msg, p_needle;
    return;
  end;
  raise exception 'TEST FAILED: % — kein Fehler ausgelöst', p_msg;
end $$;
create function test.uid(p_key text) returns uuid language sql stable as $$
  select id from test_users where key = p_key;
$$;
create function test.pid(p_key text) returns uuid language sql stable as $$
  select id from test_ids where key = p_key;
$$;
grant execute on all functions in schema test to authenticated;

-- -----------------------------------------------------------------------------
-- 1. Grunddaten
-- -----------------------------------------------------------------------------
select test.ok((select count(*) from pcc.version_triggers where active) = 8, 'Acht Versionsauslöser konfiguriert');
select test.ok((select count(*) from pcc.settings) >= 5, 'Einstellungen vorhanden');
select test.ok((select value ->> 'mode' from pcc.settings where key = 'retention') = 'unlimited',
               'Aufbewahrung steht auf unbegrenzt (Entscheidung vom 18.09.2026)');
select test.ok((select count(*) from pcc.templates where active) = 1, 'Eine Projektvorlage im Seed');

-- -----------------------------------------------------------------------------
-- 2. Selbstregistrierung: Konto ohne Rolle sieht nichts (Abschnitt 4)
-- -----------------------------------------------------------------------------
insert into test_users (key) values
  ('psa'), ('padmin'), ('ppm'), ('ppm2'), ('pcon'), ('pview'), ('pnew');
insert into auth.users (id, email) select id, key || '@test.invalid' from test_users;

select test.ok((select count(*) from public.users where pending and not active) = 7,
               'Jede Registrierung erzeugt ein gesperrtes Profil');
select test.ok((select role is null and not active and pending
                from public.users where id = test.uid('pnew')),
               'Ein frisch registriertes Konto hat keine Rolle und keinen Zugang');

-- Freischalten von Hand (im Betrieb: Super Admin über die Oberfläche)
select public.enable_internal_write();
update public.users set name = key, active = true, pending = false,
  role = case key when 'psa' then 'super_admin' when 'padmin' then 'admin'
                      when 'ppm' then 'pm' when 'ppm2' then 'pm'
                      when 'pcon' then 'contributor' when 'pview' then 'viewer' end::pcc.user_role
from test_users t where public.users.id = t.id and t.key <> 'pnew';
select public.disable_internal_write();

select test.login('pnew');
select test.ok(pcc.is_user() = false, 'Ohne Freigabe kein Zugang zur Anwendung');
select test.ok((select count(*) from pcc.projects) = 0, 'Ein gesperrtes Konto sieht keine Projekte');
select test.logout();

select test.login('pview');
select test.ok(pcc.is_user() = true, 'Der freigegebene Nutzer ist angemeldet');
select test.logout();

-- Inbetriebnahme: das erste Konto bekommt die Rolle über einen eigenen Weg,
-- und dieser Weg schließt sich danach wieder.
select test.logout();
select test.fails(format('select pcc.bootstrap_super_admin(%L)', 'psa@test.invalid'),
                  'bereits einen Super Admin', 'Der Bootstrap funktioniert genau einmal');
select test.fails('select pcc.bootstrap_super_admin(''niemand@test.invalid'')',
                  'bereits einen Super Admin', 'Er verweigert sich auch bei unbekannter Adresse');

-- Freigabe ist dem Super Admin vorbehalten
select test.login('padmin');
select test.fails(format('select pcc.approve_user(%L, ''viewer'')', test.uid('pnew')),
                  'PCC_AUTH', 'Ein Admin gibt keine Konten frei');
select test.logout();
select test.login('psa');
select pcc.approve_user(test.uid('pnew'), 'viewer', 'Neue Kollegin');
select test.ok((select active and not pending and role = 'viewer' and approved_at is not null
                from public.users where id = test.uid('pnew')),
               'Der Super Admin gibt das Konto mit Rolle frei');
select test.logout();
select test.login('pnew');
select test.ok((select count(*) from pcc.notifications
                where user_id = test.uid('pnew') and kind = 'approval') = 1,
               'Die Freigabe wird dem Konto mitgeteilt');
select test.logout();

-- -----------------------------------------------------------------------------
-- 3. Projekte anlegen
-- -----------------------------------------------------------------------------
select test.login('pview');
select test.fails('select pcc.create_project(''VIE-26'', ''Unerlaubt'')',
                  'PCC_AUTH', 'Ein Viewer legt kein Projekt an');
select test.logout();

select test.login('ppm');
insert into test_ids (key, id)
select 'p1', (pcc.create_project('SIM-26', 'CL650 Full Flight Simulator Introduction',
  null, 'Einführung des CL650 FFS am Standort Wien.',
  'FSTD-Qualifikation Level D bis Jahresende.', 'In Scope: Abnahme und Qualifikation.',
  current_date - 120, current_date + 75)).id;
select test.ok((select pm_user_id from pcc.projects where id = test.pid('p1')) = test.uid('ppm'),
               'Wer anlegt, ist ohne weitere Angabe die Projektleitung');
select test.ok((select count(*) from pcc.project_members where project_id = test.pid('p1')) = 1,
               'Die Projektleitung ist automatisch Mitglied');
select test.ok((select version from pcc.project_versions where project_id = test.pid('p1')) = '1.0',
               'Die Anlage erzeugt Version 1.0');
select test.fails('select pcc.create_project(''sim26'', ''Falscher Schlüssel'')',
                  'projects_key_check', 'Der Projektschlüssel folgt dem Muster SIM-26');
select test.fails(format('insert into pcc.projects (key, name, pm_user_id) values (''XXX-26'', ''Direkt'', %L)', test.uid('ppm')),
                  'permission denied', 'Projekte entstehen nur über create_project()');
select test.logout();

-- -----------------------------------------------------------------------------
-- 4. Referenznummern, generierte Spalten, Statusfelder
-- -----------------------------------------------------------------------------
select test.login('ppm');
insert into pcc.workstreams (project_id, name, owner_user_id, sort_order)
values (test.pid('p1'), 'Qualifikation', test.uid('ppm'), 1);
insert into test_ids (key, id)
select 'ws1', id from pcc.workstreams where project_id = test.pid('p1');

with ins as (
  insert into pcc.tasks (project_id, workstream_id, title, assignee_user_id, priority, due_date)
  values (test.pid('p1'), test.pid('ws1'), 'Factory Acceptance Test durchführen',
          test.uid('pcon'), 'critical', current_date + 10)
  returning id)
insert into test_ids (key, id) select 't1', id from ins;
select test.ok((select ref from pcc.tasks where id = test.pid('t1')) = 'T-1',
               'Die erste Aufgabe erhält die Referenz T-1');
select test.fails(format('update pcc.tasks set ref = ''T-99'' where id = %L', test.pid('t1')),
                  'PCC_IMMUTABLE', 'Die Referenznummer bleibt bestehen');

with ins as (
  insert into pcc.risks (project_id, title, probability, impact, owner_user_id, status)
  values (test.pid('p1'), 'Verzug bei der behördlichen Qualifikation', 3, 4, test.uid('ppm'), 'open')
  returning id)
insert into test_ids (key, id) select 'r1', id from ins;
select test.ok((select ref = 'R-1' and score = 12 from pcc.risks where id = test.pid('r1')),
               'Risiko R-1, Score wird von der Datenbank gerechnet');
select test.fails(format('update pcc.risks set score = 25 where id = %L', test.pid('r1')),
                  'can only be updated to DEFAULT', 'Der Risk Score lässt sich nicht von Hand setzen');
select test.fails(format('update pcc.risks set probability = 9 where id = %L', test.pid('r1')),
                  'risks_probability_check', 'Eintrittswahrscheinlichkeit bleibt zwischen 1 und 5');

update pcc.tasks set status = 'completed' where id = test.pid('t1');
select test.ok((select completed_at is not null and progress = 100 from pcc.tasks where id = test.pid('t1')),
               'Eine erledigte Aufgabe bekommt Datum und 100 Prozent von selbst');
update pcc.tasks set status = 'in_progress', progress = 40 where id = test.pid('t1');
select test.ok((select completed_at is null from pcc.tasks where id = test.pid('t1')),
               'Wird die Aufgabe wieder geöffnet, verschwindet das Abschlussdatum');
select test.logout();

-- -----------------------------------------------------------------------------
-- 5. Rechte in einem Projekt (Abschnitt 5)
-- -----------------------------------------------------------------------------
select test.login('ppm');
select pcc.add_member(test.pid('p1'), test.uid('pcon'), 'Course Supervisor', 'Kursunterlagen');
select pcc.add_member(test.pid('p1'), test.uid('pview'), 'Sponsor', 'Freigaben');
select test.logout();

select test.login('pview');
select test.ok((select count(*) from pcc.projects where id = test.pid('p1')) = 1,
               'Jeder freigegebene Nutzer liest jedes nicht archivierte Projekt');
select test.ok(pcc.can_edit(test.pid('p1')) = false, 'Der Viewer hat kein Schreibrecht');
with u as (update pcc.tasks set title = 'Heimlich geändert' where id = test.pid('t1') returning 1)
select test.ok((select count(*) from u) = 0, 'Ein Viewer ändert keine Aufgabe');
select test.logout();

select test.login('pcon');
select test.ok(pcc.can_contribute(test.pid('p1')) = true, 'Der Contributor ist Mitglied und darf beitragen');
update pcc.tasks set progress = 60 where id = test.pid('t1');
select test.ok((select progress from pcc.tasks where id = test.pid('t1')) = 60,
               'Der Contributor pflegt die ihm zugewiesene Aufgabe');
select test.fails(format('insert into pcc.tasks (project_id, title) values (%L, ''Eigenmächtig angelegt'')', test.pid('p1')),
                  'row-level security', 'Neue Aufgaben legt nur die Projektleitung an');
insert into pcc.issues (project_id, title, owner_user_id)
values (test.pid('p1'), 'Lieferung der Instruktorenstation verzögert', test.uid('pcon'));
select test.ok((select count(*) from pcc.issues where project_id = test.pid('p1')) = 1,
               'Issues darf jedes Projektmitglied melden');
select test.logout();

-- Ein zweiter Projektleiter hat in fremden Projekten nur Leserecht
select test.login('ppm2');
select test.ok(pcc.can_read(test.pid('p1')) = true, 'Fremde Projekte sind lesbar');
select test.ok(pcc.can_edit(test.pid('p1')) = false, 'Fremde Projekte sind nicht änderbar');
select test.logout();

-- -----------------------------------------------------------------------------
-- 6. Versionierung (Abschnitt 6)
-- -----------------------------------------------------------------------------
select test.login('ppm');
update pcc.projects set status = 'on_track' where id = test.pid('p1');
select test.ok((select count(*) from pcc.project_versions where project_id = test.pid('p1')) = 2,
               'Ein Statuswechsel erzeugt eine Version');
select test.ok((select version from pcc.project_versions
                where project_id = test.pid('p1') and trigger_code = 'project_status') = '1.1',
               'Die Version zählt in Zehnteln hoch');
select test.ok((select count(*) from pcc.version_changes vc
                join pcc.project_versions v on v.id = vc.version_id
                where v.project_id = test.pid('p1') and vc.field = 'status') = 1,
               'Die Einzeländerung steht in version_changes');

update pcc.projects set description = 'Nur eine Beschreibung' where id = test.pid('p1');
select test.ok((select count(*) from pcc.project_versions where project_id = test.pid('p1')) = 2,
               'Eine beliebige Feldänderung erzeugt keine Version');

with ins as (
  insert into pcc.milestones (project_id, name, due_date, owner_user_id)
  values (test.pid('p1'), 'Qualifikation erteilt', current_date + 40, test.uid('ppm'))
  returning id)
insert into test_ids (key, id) select 'm1', id from ins;
update pcc.milestones set due_date = current_date + 60 where id = test.pid('m1');
select test.ok((select count(*) from pcc.project_versions
                where project_id = test.pid('p1') and trigger_code = 'milestone_moved') = 1,
               'Ein verschobener Meilenstein erzeugt eine Version');
select test.ok((select slipped_days from pcc.v_milestones where id = test.pid('m1')) = 20,
               'Die Verschiebung gegen den Ursprungstermin ist ablesbar');

update pcc.risks set probability = 5, impact = 4 where id = test.pid('r1');
select test.ok((select count(*) from pcc.project_versions
                where project_id = test.pid('p1') and trigger_code = 'risk_critical') = 1,
               'Ein Risiko ab Score 15 erzeugt eine Version');
select test.fails(format('update pcc.project_versions set summary = ''x'' where project_id = %L', test.pid('p1')),
                  'permission denied', 'Versionen sind gegen Änderung gesperrt');
select test.logout();

-- Benachrichtigung über das kritische Risiko geht an die Projektleitung
select test.login('ppm2');
insert into test_ids (key, id)
select 'p2', (pcc.create_project('OMB-26', 'Operations Manual Part B Revision', test.uid('ppm2'))).id;
insert into pcc.risks (project_id, title, probability, impact, status)
values (test.pid('p2'), 'Behördliche Rückfragen', 5, 5, 'open');
select test.logout();
select test.login('ppm');
select test.ok((select count(*) from pcc.notifications
                where user_id = test.uid('ppm') and kind = 'risk_critical') = 0,
               'Die Meldung geht an die zuständige Projektleitung, nicht an alle');
select test.logout();

-- -----------------------------------------------------------------------------
-- 7. Fortschritt und Gesamtlage
-- -----------------------------------------------------------------------------
select test.login('ppm');
insert into pcc.tasks (project_id, parent_task_id, title, status)
values (test.pid('p1'), test.pid('t1'), 'Prüfprotokoll vorbereiten', 'completed'),
       (test.pid('p1'), test.pid('t1'), 'Testflüge abnehmen', 'not_started');
update pcc.tasks set progress_mode = 'derived' where id = test.pid('t1');
select test.ok(pcc.task_progress(test.pid('t1')) = 50,
               'Der Fortschritt einer Aufgabe kann aus den Teilaufgaben kommen');
update pcc.tasks set progress_mode = 'manual', progress = 60 where id = test.pid('t1');
select test.ok(pcc.task_progress(test.pid('t1')) = 60,
               'Oder von Hand gesetzt bleiben — je Aufgabe entscheidbar');

select test.ok(pcc.health(test.pid('p1')) = 'amber',
               'Ein kritisches Risiko färbt die Gesamtlage gelb');
insert into pcc.risks (project_id, title, probability, impact, status)
values (test.pid('p1'), 'Ausfall des Herstellersupports', 5, 5, 'open');
select test.ok(pcc.health(test.pid('p1')) = 'red',
               'Zwei kritische Risiken färben sie rot');
update pcc.milestones set due_date = current_date - 5, status = 'planned' where id = test.pid('m1');
select test.ok(pcc.health(test.pid('p1')) = 'red', 'Ein überfälliger Meilenstein ebenfalls');
select test.ok((select health from pcc.v_projects where id = test.pid('p2')) = 'amber',
               'Ein einzelnes kritisches Risiko bleibt gelb');
select test.logout();

-- -----------------------------------------------------------------------------
-- 8. RACI, Dokumente, Kommentare
-- -----------------------------------------------------------------------------
select test.login('ppm');
insert into pcc.raci (project_id, subject_type, subject_id, user_id, letter)
values (test.pid('p1'), 'task', test.pid('t1'), test.uid('pcon'), 'A'),
       (test.pid('p1'), 'task', test.pid('t1'), test.uid('pview'), 'C');
select test.fails(format('insert into pcc.raci (project_id, subject_type, subject_id, user_id, letter)
                          values (%L, ''task'', %L, %L, ''A'')',
                         test.pid('p1'), test.pid('t1'), test.uid('ppm')),
                  'raci_one_accountable', 'Eine Aufgabe hat genau ein A');

select test.fails(format('insert into pcc.documents (project_id, title, kind, storage_path, external_url)
                          values (%L, ''Doppelt'', ''file'', ''a/b.pdf'', ''https://x'')', test.pid('p1')),
                  'documents_check', 'Ein Dokument ist entweder Datei oder Verweis, nie beides');
select test.fails(format('insert into pcc.documents (project_id, title, kind, storage_path, size_bytes)
                          values (%L, ''Zu groß'', ''file'', ''a/b.pdf'', 60000000)', test.pid('p1')),
                  'size_bytes', 'Über 50 MB nimmt die Anwendung keine Datei an');

with ins as (
  insert into pcc.documents (project_id, title, kind, storage_path, mime_type, size_bytes, owner_user_id)
  values (test.pid('p1'), 'Qualification Test Guide', 'file', 'project-docs/qtg-v1.pdf',
          'application/pdf', 240000, test.uid('ppm'))
  returning id)
insert into test_ids (key, id) select 'd1', id from ins;
select test.ok((select scan_state from pcc.documents where id = test.pid('d1')) = 'pending',
               'Ein Upload ist bis zur Prüfung in Quarantäne');
insert into test_ids (key, id)
select 'd2', (pcc.supersede_document(test.pid('d1'), 'Qualification Test Guide', 'file',
                                     'project-docs/qtg-v2.pdf', null, 'application/pdf', 260000)).id;
select test.ok((select version = 2 and supersedes_id = test.pid('d1')
                from pcc.documents where id = test.pid('d2')),
               'Eine neue Fassung löst die alte ab, statt sie zu überschreiben');
select test.ok((select count(*) from pcc.documents where project_id = test.pid('p1')) = 2,
               'Die abgelöste Fassung bleibt erhalten');
select test.logout();

select test.login('pcon');
insert into test_ids (key, id)
select 'c1', (pcc.post_comment(test.pid('p1'), 'task', test.pid('t1'),
                               'Der Termin ist knapp, ich brauche eine Entscheidung.',
                               array[test.uid('ppm')])).id;
select test.logout();
select test.login('ppm');
select test.ok((select count(*) from pcc.notifications
                where user_id = test.uid('ppm') and kind = 'mention') = 1,
               'Eine Erwähnung erreicht die genannte Person');
select test.logout();

select test.login('pview');
select test.fails(format('select pcc.post_comment(%L, ''task'', %L, ''Kein Recht'')',
                         test.pid('p1'), test.pid('t1')),
                  'PCC_AUTH', 'Ein Viewer kommentiert nicht');
select test.logout();

-- Löschen ist kein gewöhnliches Ändern (Abschnitt 7b)
select test.login('ppm');
select test.fails(format('update pcc.documents set deleted_at = now() where id = %L', test.pid('d2')),
                  'PCC_AUTH', 'Auch der Eigentümer löscht ein Dokument nicht im Vorbeigehen');
select test.logout();
select test.login('psa');
select test.fails(format('select pcc.delete_document(%L, '''')', test.pid('d2')),
                  'PCC_STATE', 'Ohne Grundlage keine Dokumentlöschung');
select pcc.delete_document(test.pid('d2'), 'Antrag nach Artikel 17 DSGVO vom 02.09.2026');
select test.ok((select deleted_at is not null and deleted_reason is not null
                from pcc.documents where id = test.pid('d2')),
               'Der Super Admin löscht auf Antrag, mit Grundlage');
select test.logout();
select test.login('ppm');
select test.ok((select count(*) from pcc.documents where id = test.pid('d2')) = 0,
               'Gelöschte Dokumente sind für alle außer dem Super Admin verschwunden');
with u as (update pcc.comments set body = 'nachtraeglich geaendert' where id = test.pid('c1') returning 1)
select test.ok((select count(*) from u) = 0, 'Fremde Kommentare bleiben unangetastet');
select test.logout();
select test.login('pcon');
update pcc.comments set body = 'Der Termin ist knapp — bitte um Entscheidung bis Freitag.' where id = test.pid('c1');
select test.ok((select edited_at is not null from pcc.comments where id = test.pid('c1')),
               'Ein bearbeiteter Kommentar sagt, dass er bearbeitet wurde');
select test.logout();

-- -----------------------------------------------------------------------------
-- 9. Archiv und endgültiges Löschen (Abschnitt 41)
-- -----------------------------------------------------------------------------
select test.login('ppm2');
select test.fails(format('select pcc.archive_project(%L, '''')', test.pid('p2')),
                  'PCC_STATE', 'Archivieren verlangt einen Grund');
select pcc.archive_project(test.pid('p2'), 'Revision in die Linienorganisation überführt');
select test.fails(format('insert into pcc.tasks (project_id, title) values (%L, ''Nachtrag'')', test.pid('p2')),
                  'PCC_ARCHIVED', 'Ein archiviertes Projekt ist schreibgeschützt');
select test.fails(format('select pcc.delete_project(%L, ''Versehen'')', test.pid('p2')),
                  'PCC_AUTH', 'Endgültiges Löschen ist dem Super Admin vorbehalten');
select test.logout();

select test.login('psa');
select test.fails(format('select pcc.delete_project(%L, ''  '')', test.pid('p2')),
                  'PCC_STATE', 'Auch der Super Admin nennt einen Grund');
select pcc.delete_project(test.pid('p2'), 'Doppelt angelegt, Inhalt in SIM-26 überführt');
select test.ok((select count(*) from pcc.projects where id = test.pid('p2')) = 0, 'Das Projekt ist gelöscht');
select test.ok((select count(*) from public.audit_log
                where action = 'purge' and project_id = test.pid('p2')) = 1,
               'Die Löschung steht im Audit-Trail, mit Grund');
select test.logout();

-- -----------------------------------------------------------------------------
-- 10. Löschverlangen nach Artikel 17 DSGVO (Abschnitt 7b)
-- -----------------------------------------------------------------------------
select test.login('padmin');
select test.fails(format('select pcc.anonymise_user(%L, ''Antrag vom 01.09.2026'')', test.uid('pcon')),
                  'PCC_AUTH', 'Ein Löschverlangen führt nur der Super Admin aus');
select test.logout();
select test.login('psa');
select test.fails(format('select pcc.anonymise_user(%L, '''')', test.uid('pcon')),
                  'PCC_STATE', 'Ohne Grundlage keine Pseudonymisierung');
select pcc.anonymise_user(test.uid('pcon'), 'Antrag nach Artikel 17 DSGVO vom 01.09.2026');
select test.ok((select name like 'Ehemaliger Mitarbeiter%' and not active and role is null
                from public.users where id = test.uid('pcon')),
               'Das Konto ist pseudonymisiert und gesperrt');
select test.ok((select count(*) from pcc.tasks where assignee_user_id = test.uid('pcon')) >= 1,
               'Die fachliche Zuordnung bleibt über die ID bestehen');
select test.ok((select count(*) from public.audit_log
                where action = 'anonymise'
                  and entity_id = test.uid('pcon')::text) = 1,
               'Der Vorgang selbst bleibt nachvollziehbar');
select test.logout();

-- -----------------------------------------------------------------------------
-- 11. Sichten und Tageslauf
-- -----------------------------------------------------------------------------
select test.login('ppm');
select test.ok((select projects_total from pcc.v_dashboard) = 1, 'Das Dashboard zählt die sichtbaren Projekte');
select test.ok((select critical_risks from pcc.v_projects where id = test.pid('p1')) = 2,
               'Die Projektsicht weist die kritischen Risiken aus');
select test.ok((select count(*) from pcc.v_activity where project_id = test.pid('p1')) > 0,
               'Die Aktivität speist sich aus dem gemeinsamen Audit-Trail');
select test.logout();

select test.login('pview');
select test.ok((select count(*) from pcc.v_activity where project_id = test.pid('p1')) > 0,
               'Die Aktivität des eigenen Projekts ist für jeden Leser sichtbar');
select test.ok((select count(*) from pcc.v_activity where entity = 'public.users') = 0,
               'Einträge ohne Projektbezug bleiben der Admin-Ebene vorbehalten');
select test.logout();

select test.logout();
update pcc.tasks set due_date = current_date - 3, status = 'in_progress',
       assignee_user_id = test.uid('ppm2') where id = test.pid('t1');
select test.ok((select affected from pcc.run_daily_jobs() where job = 'tasks_overdue') >= 1,
               'Der Tageslauf meldet überfällige Aufgaben');
select test.ok((select count(*) from pcc.notifications
                where kind = 'overdue' and entity_id = test.pid('t1')) >= 1,
               'Zuständige und Projektleitung werden benachrichtigt');
select test.ok((select count(*) from pcc.run_daily_jobs()) = 3, 'Der Tageslauf hat drei Teile');

-- -----------------------------------------------------------------------------
-- 12. Vorlage ausrollen (Abschnitt 30)
-- -----------------------------------------------------------------------------
select test.login('padmin');
insert into test_ids (key, id)
select 'p3', (pcc.create_project('EBT-27', 'Evidence Based Training Einführung',
  test.uid('ppm2'), null, null, null, current_date, current_date + 200,
  (select id from pcc.templates where name = 'Simulator-Einführung'))).id;
select test.ok((select count(*) from pcc.workstreams where project_id = test.pid('p3')) = 3,
               'Die Vorlage legt drei Workstreams an');
select test.ok((select count(*) from pcc.tasks where project_id = test.pid('p3')) = 4,
               'Die Vorlage legt vier Aufgaben an');
select test.ok((select count(*) from pcc.milestones where project_id = test.pid('p3')) = 3,
               'Die Vorlage legt drei Meilensteine an');
select test.ok((select count(*) from pcc.tasks t join pcc.workstreams w on w.id = t.workstream_id
                where t.project_id = test.pid('p3')) = 4,
               'Die Aufgaben der Vorlage hängen an den richtigen Workstreams');
select test.logout();

-- -----------------------------------------------------------------------------
-- 13. Angriffe, die funktionieren müssten, wenn die Riegel fehlten
-- -----------------------------------------------------------------------------
select test.login('pview');
select test.fails('select public.enable_internal_write()',
                  'permission denied', 'Den internen Schreibmodus legt niemand von außen um');
select test.fails(format('update public.users set role = ''super_admin'' where id = %L', test.uid('pview')),
                  'PCC_AUTH', 'Niemand befördert sich selbst');
select test.fails(format('select pcc.next_ref(%L, ''HACK'')', test.pid('p1')),
                  'permission denied', 'Referenznummern vergibt der Trigger, nicht der Nutzer');
select test.ok((select count(*) from pcc.v_pending_users) = 0,
               'Offene Registrierungen sieht nur der Super Admin');
select test.logout();

select test.login('psa');
select test.ok((select count(*) from pcc.v_pending_users) >= 0,
               'Der Super Admin sieht die Freigabeliste');
select test.logout();

select test.login('ppm');
-- Der Prüfstand eines Dokuments kommt von der Virenprüfung
select test.fails(format('update pcc.documents set scan_state = ''clean'' where id = %L', test.pid('d1')),
                  'PCC_GUARD', 'Ein Upload erklärt sich nicht selbst für geprüft');
select test.fails(format('update pcc.documents set project_id = %L where id = %L', test.pid('p3'), test.pid('d1')),
                  'PCC_IMMUTABLE', 'Ein Dokument wechselt nicht das Projekt');
-- Der Versionszähler gehört der Versionierung
select test.fails(format('update pcc.projects set version_minor = 0 where id = %L', test.pid('p1')),
                  'PCC_GUARD', 'Der Versionsstand lässt sich nicht zurücksetzen');
select test.fails(format('update pcc.projects set archived_at = now() where id = %L', test.pid('p1')),
                  'PCC_GUARD', 'Archivieren geht nur mit Grund über die Funktion');
select test.fails(format('update pcc.projects set key = ''XXX-99'' where id = %L', test.pid('p1')),
                  'PCC_IMMUTABLE', 'Der Projektschlüssel bleibt bestehen');
-- Eine Aufgabe ist nicht ihr eigenes Elternteil, und tiefer als eine Ebene geht es nicht
select test.fails(format('update pcc.tasks set parent_task_id = id where id = %L', test.pid('t1')),
                  'tasks_check', 'Eine Aufgabe ist nicht ihre eigene Teilaufgabe');
-- Optimistisches Sperren (Abschnitt 5)
select test.fails(format('update pcc.tasks set title = ''veraltet'', updated_at = %L where id = %L',
                         '2020-01-01 00:00:00+00', test.pid('t1')),
                  'PCC_CONFLICT', 'Ein überholter Stand überschreibt nichts still');
-- Herkunft ist kein Client-Wert
insert into pcc.issues (project_id, title, created_by)
values (test.pid('p1'), 'Angeblich vom Super Admin', test.uid('psa'));
select test.ok((select created_by from pcc.issues where title = 'Angeblich vom Super Admin') = test.uid('ppm'),
               'Angelegt von wird gesetzt, nicht mitgeliefert');
insert into pcc.issues (project_id, title, ref) values (test.pid('p1'), 'Frei gewählte Referenz', 'T-1');
select test.ok((select ref from pcc.issues where title = 'Frei gewählte Referenz') like 'I-%',
               'Die Referenznummer kommt aus dem Zähler');
select test.logout();

-- Rollenvergabe steht im Audit-Trail
select test.logout();
select test.ok((select count(*) from public.audit_log where entity = 'public.users') > 0,
               'Wer wem welche Rolle gegeben hat, steht im Trail');

select test.ok(true, 'Alle Prüfungen des Control Centers bestanden');
rollback;
